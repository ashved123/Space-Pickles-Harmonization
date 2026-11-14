import pandas as pd
from sklearn.ensemble import RandomForestRegressor
import warnings
warnings.filterwarnings('ignore')

# 1. Load datasets
df_daily = pd.read_csv("harmonized_daily_grid_0p25deg.csv")
df_monthly = pd.read_csv("harmonized_monthly_region.csv")

# 2. Extract dates
df_daily['date'] = pd.to_datetime(df_daily['date'])
df_daily['year'] = df_daily['date'].dt.year
df_daily['month_num'] = df_daily['date'].dt.month
df_daily['day_of_year'] = df_daily['date'].dt.dayofyear

# 3. Feature Engineering
macro_trends = df_monthly[['year', 'month_num', 'baseline_median']]
df_merged = pd.merge(df_daily, macro_trends, on=['year', 'month_num'], how='left')
df_merged = df_merged.dropna(subset=['raw_frp_mw', 'baseline_median'])

# 4. Define Features (X) and Target (y)
features = ['year', 'month_num', 'day_of_year', 'lat_center', 'lon_center', 'baseline_median']
X = df_merged[features]
y = df_merged['raw_frp_mw']

# 5. Train the Model
model = RandomForestRegressor(n_estimators=50, random_state=42, n_jobs=-1)
model.fit(X, y)

# 6. Generate dates and predict
future_dates = pd.date_range(start="2027-01-01", end="2027-12-31")
future_df = pd.DataFrame({
    'date': future_dates,
    'year': future_dates.year,
    'month_num': future_dates.month,
    'day_of_year': future_dates.dayofyear,
    'lat_center': 34.125,     
    'lon_center': -118.125,   
})

baseline_map = df_monthly.groupby('month_num')['baseline_median'].mean().to_dict()
future_df['baseline_median'] = future_df['month_num'].map(baseline_map)
future_df['predicted_frp_mw'] = model.predict(future_df[features])

# 7. Convert to Risk Level and Scaled 1-100 Confidence
def get_risk(frp):
    if frp > 50: return "High"
    elif frp > 15: return "Medium"
    else: return "Low"

def get_confidence(frp):
    # Scales relative to the 50 MW "High" risk threshold
    score = int((frp / 50.0) * 100)
    return min(max(score, 1), 100) 

future_df['risk'] = future_df['predicted_frp_mw'].apply(get_risk)
future_df['confidence'] = future_df['predicted_frp_mw'].apply(get_confidence)

# Clean up names for the UI
future_df['date'] = future_df['date'].dt.strftime('%Y-%m-%d')
final_output = future_df[['date', 'lat_center', 'lon_center', 'risk', 'confidence']]
final_output.rename(columns={'lat_center': 'lat', 'lon_center': 'lon'}, inplace=True)

# 8. Print sample and save JSON
print("\n--- SAMPLE UI DATA (5 Random Days) ---")
print(final_output.sample(5).to_string(index=False))
print("--------------------------------------\n")

final_output.to_json("calendar_ready_2027.json", orient='records', indent=4)
print("Saved 365 days to calendar_ready_2027.json.")
