# Fire sim calibration

How `app/sim/fire_sim.gd` was tuned on 2026-11-14, and why it differs from Alexandridis et al. (2008).
All numbers are from `app/calibrate.gd`: flat terrain, uniform shrub (fuel class 3), 150 m cells,
10 seeds per setting, wind toward east. Output is **simulated**; this is a planning/training what-if tool,
not a prediction. Final tuning should come from validation against a real fire (Camp Fire, 2018).

## Targets (from the literature, not guesses)

| What | Target | Source |
|---|---|---|
| No-wind shape | Round: diagonal reach / straight reach = 1.0 (a square gives 1.41) | geometry |
| Wind-driven shape | Length/breadth `L/B = 1 + 0.25·U_mid`, U_mid in mi/h | Andrews 2018 (GTR-371) |
| 10 m wind → mid-flame | `U_mid = 0.4 · U10 / 1.15` (÷1.15 for 10 m → 20 ft; WAF 0.4 unsheltered) | Andrews 2012 (GTR-266) |
| Head speed | ≈ 10% of the 10 m wind speed (forests and shrublands, dry fuel) | Cruz & Alexander 2019 |

With 10 m wind V in m/s, the shape target is about L/B = 1 + 0.195·V: 1.6 at 3 m/s, 2.0 at 5, 2.6 at 8, 3.0 at 10.

## What was wrong with the paper's model as written

Paper constants (`p_h 0.58, c1 0.045, c2 0.131`), cells burn for one step:

| p_h | wind m/s | head cells/step | L/B (target) | no-wind roundness |
|---|---|---|---|---|
| 0.58 | 0 | 1.00 | 1.00 (1.00) | 1.32 |
| 0.58 | 5 | 1.00 | 0.92 (1.97) | |
| 0.58 | 8 | 1.00 | 0.75 (2.56) | |
| 0.32 | 8 | 0.91 | 10.2 (2.56) | |

- The head is stuck at the 1 cell/step limit at every wind speed, so wind doesn't make it faster.
- Fires come out square-ish and, at moderate wind, wider than long (L/B < 1).
- Lowering `p_h` just makes the flanks drop below the spread threshold and die, so the fire turns into a spike.

## Changes

1. **Multi-step burning.** A cell burns for `burn_steps` steps and tries its unburnt neighbours on each one,
   so `p_burn` acts as a per-step chance (a rate), not a one-shot coin flip. Diagonal neighbours are
   farther away (√2), so their chance is scaled by `diag_factor = 0.707`. This alone fixes the no-wind
   shape (roundness 1.20 → 1.01 at p_h 0.2).
2. **Elliptical wind term.** The paper's `exp(c1·V)·exp(c2·V·(cos θ − 1))` drops sideways/backward chances
   exponentially, below the spread threshold. Replaced with the fire-ellipse spread-by-direction
   relation (Andrews 2018): `p_wind = (1 + wind_gain·V) · ((1 − e)/(1 − e·cos θ))^shape_k`, with
   eccentricity `e = √(Z² − 1)/Z`, Z = target L/B. Flanks and backing fire slow down but keep going.
3. **Wind-dependent step length.** On a lattice the head can't spread faster than 1 cell/step, so the head
   speed can't follow the wind through probabilities alone (tested up to `wind_gain` 1.2: head grew only
   1.3× from 5 to 10 m/s). The region has one wind value per hour, so instead the real time per step
   follows the wind: `step_minutes = head_cells_per_step(V) · cell_size / (0.1 · V)`. The probabilities set
   the shape; the step length sets the speed.

## Chosen constants and result

`p_h 0.06, wind_gain 0.3, shape_k 1.0, diag_factor 0.7071, burn_steps 24` (a 0.078 unchanged):

| wind m/s | head cells/step | L/B (target) | no-wind roundness | min/step | head km/h |
|---|---|---|---|---|---|
| 0 | 0.341 | 1.00 (1.00) | 1.00 | 4.2 | 0.7* |
| 2 | 0.373 | 1.30 (1.39) | | 4.7 | 0.7 |
| 3 | 0.379 | 1.40 (1.58) | | 3.3 | 1.1 |
| 5 | 0.423 | 1.79 (1.97) | | 2.1 | 1.8 |
| 8 | 0.477 | 2.39 (2.56) | | 1.5 | 2.9 |
| 10 | 0.514 | 3.28 (2.95) | | 1.3 | 3.6 |
| 12 | 0.543 | 4.40 (3.33) | | 1.2 | 4.3 |
| 15 | 0.615 | 7.13 (3.92) | | 1.0 | 5.4 |

Head cells/step fit: `0.3362 + 0.01798·V` (max error 0.011), stored as `HEAD_CPS_0` / `HEAD_CPS_PER_MS`.
Fires never died out in any setting (10/10 seeds).

## Known limits

- **L/B is 5–12% low from 2–8 m/s and too high above ~10 m/s** (7.1 vs 3.9 at 15 m/s): in very strong wind the
  flanks get close to the spread threshold again.
- *Below 2 m/s the 10% rule is held at its 2 m/s value.* The rule isn't meant for near-calm conditions; this
  floor is our assumption and should be replaced by the Camp Fire calibration.
- **Speed is calibrated on shrub only.** Other fuels differ through the paper's p_veg values (grass 0.3,
  shrub 0.4, timber litter 0.0), which are much smaller differences than real fuels show. Fixing this
  needs fuel-specific rates and is a data-contract discussion with the pipeline owner.
- **The burning band is deeper than a real flame front** (each cell stays BURNING for 24 steps, ~50 min at
  5 m/s). Treat BURNING as "active fire area", not flame depth.
- **Cost:** about 10× more steps per fire (bench: ~1550 steps, ~675 ms per full fire vs ~29 ms before;
  worst step 1.9 ms). Fine for interactive play; the Monte Carlo risk map may need to be precomputed offline.

## Fuel moisture (humidity and temperature)

Added after the wind calibration. Weather is one value for the whole region per hour, like wind.

1. Equilibrium moisture content from relative humidity h (%) and temperature T (°F), Simard (1968) as
   printed in Ottmar & Sandberg (1985), eqs. 4a–4c:
   - h < 10%: `EMC = 0.03229 + 0.281073·h − 0.000578·h·T`
   - 10% ≤ h ≤ 50%: `EMC = 2.22749 + 0.160107·h − 0.014784·T`
   - h > 50%: `EMC = 21.0606 + 0.005565·h² − 0.00035·h·T − 0.483199·h`
2. Fine (1-hour) dead fuel moisture `M = 1.03·EMC` (Bradshaw et al. 1984, eq. 26, the midafternoon
   simplification; we use it every hour).
3. Rothermel's moisture effect on spread (Andrews 2018): reaction intensity ∝ `ηM = 1 − 2.59r + 5.11r² − 3.52r³`,
   `r = M/Mx`, and spread ∝ 1 / heat of preignition `Qig = 250 + 1116·M`. So the factor is
   `f(M) = [ηM/Qig](M) / [ηM/Qig](M_REF)`, 0 at or above Mx.
4. Mx per fuel class: Scott & Burgan (2005) arid/semiarid models (California): grass, grass-shrub, shrub 15%;
   timber-understory 20%; timber litter, slash 25%.
5. The fastest fuel's factor stretches the step time (like the wind); every other fuel's `p_burn` is scaled by
   its factor relative to the fastest.

At 25 °C, 5 m/s wind, flat shrub:

| RH | fuel moisture | head spread | min/step |
|---|---|---|---|
| 30% | 6.1% | 1.8 km/h | 2.1 |
| 65% | 11.8% | 1.1 km/h | 2.9 |
| 95% | 23.5% | 0 (shrub extinct; only TL/SB creep) | 13.7 |

Test: 3 h of sim time at 60% vs 20% RH burns 4,638 vs 10,611 cells (10 seeds).

Limits: `M_REF = 6%` (the moisture behind the 10% rule calibration) is our assumption. Live fuel moisture
(important in chaparral) isn't modelled. Moisture lag is ignored (fine fuels respond within about an hour).

## Re-running

```
godot --headless --path app -s calibrate.gd -- "p_h,wind_gain,shape_k,diag_factor,burn_steps"
```
Several settings can be separated with `;`. After changing any of these constants, update
`HEAD_CPS_0` / `HEAD_CPS_PER_MS` from a linear fit of the head column, then run `test_fire_sim.gd`.
