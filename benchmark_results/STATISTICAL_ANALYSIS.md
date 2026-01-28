# Desktop Environment Benchmark: Statistical Analysis Report

## XFCE vs Cinnamon Power Consumption Analysis

**Date:** January 27, 2026  
**System:** 12th Gen Intel Core i7-1260P, 16 cores, 15GB RAM  
**Significance Level:** α = 0.10

---

## 1. Data Collection

| Environment | Battery Samples | AC Samples | Total |
| ----------- | --------------- | ---------- | ----- |
| XFCE        | 290             | 180        | 470   |
| Cinnamon    | 284             | 180        | 464   |

**Phases tested:** Light, Medium-Heavy, Heavy, Ultra-Heavy tasks

---

## 2. Descriptive Statistics (Battery Power)

### XFCE

```
n₁ = 290
Mean (x̄₁) = 25.42 W
Std Dev (s₁) = 2.97
Variance (s₁²) = 8.80
Standard Error (SE₁ = s₁/√n₁) = 0.174
```

### Cinnamon

```
n₂ = 284
Mean (x̄₂) = 27.98 W
Std Dev (s₂) = 2.03
Variance (s₂²) = 4.10
Standard Error (SE₂ = s₂/√n₂) = 0.120
```

---

## 3. Welch's t-Test (Aggregated)

### Formula

The t-statistic for Welch's t-test (unequal variances):

$$t = \frac{\bar{x}_1 - \bar{x}_2}{\sqrt{\frac{s_1^2}{n_1} + \frac{s_2^2}{n_2}}}$$

### Calculation

**Step 1: Difference of means**

```
x̄₁ - x̄₂ = 25.42 - 27.98 = -2.56 W
```

**Step 2: Standard Error of difference**

```
SE_diff = √(SE₁² + SE₂²)
SE_diff = √(0.174² + 0.120²)
SE_diff = √(0.0303 + 0.0144)
SE_diff = 0.212
```

**Step 3: t-statistic**

```
t = (x̄₁ - x̄₂) / SE_diff
t = -2.56 / 0.212
t = -12.09
```

**Step 4: Degrees of freedom (Welch-Satterthwaite)**

```
df = [(s₁²/n₁ + s₂²/n₂)²] / [(s₁²/n₁)²/(n₁-1) + (s₂²/n₂)²/(n₂-1)]
df = 511.22
```

**Step 5: p-value (two-tailed)**

```
p = 2 × P(T < -12.09 | df=511.22)
p < 0.0001
```

### Result (Aggregated)

```
✓ SIGNIFICANT at α = 0.10
  XFCE uses 2.56W less power on battery (p < 0.0001)
```

---

## 4. Stratified Analysis by Task Phase

> **Note:** Aggregating all samples together is not best practice. We stratify by task type for proper analysis.

### Battery Mode Results

| Phase  | n_XFCE | n_Cinn | XFCE Mean | SE    | Cinn Mean | SE    | t-stat | p-value | Winner       |
| ------ | ------ | ------ | --------- | ----- | --------- | ----- | ------ | ------- | ------------ |
| Light  | 75     | 75     | 22.36     | 0.427 | 26.50     | 0.257 | -8.31  | <0.001  | **XFCE**     |
| Medium | 76     | 73     | 25.15     | 0.150 | 29.80     | 0.133 | -23.22 | <0.001  | **XFCE**     |
| Heavy  | 73     | 72     | 26.89     | 0.130 | 28.76     | 0.171 | -8.73  | <0.001  | **XFCE**     |
| Ultra  | 66     | 64     | 27.61     | 0.175 | 26.79     | 0.053 | +4.49  | <0.001  | **Cinnamon** |

### AC Mode Results

| Phase  | n_XFCE | n_Cinn | XFCE Mean | SE    | Cinn Mean | SE    | t-stat | p-value | Winner       |
| ------ | ------ | ------ | --------- | ----- | --------- | ----- | ------ | ------- | ------------ |
| Light  | 47     | 47     | 21.03     | 0.309 | 20.82     | 0.316 | +0.49  | 0.622   | No diff      |
| Medium | 47     | 47     | 23.69     | 0.008 | 23.63     | 0.009 | +4.79  | <0.001  | Cinn (0.06W) |
| Heavy  | 46     | 47     | 23.64     | 0.006 | 23.62     | 0.004 | +2.68  | 0.009   | Cinn (0.02W) |
| Ultra  | 40     | 39     | 23.85     | 0.015 | 23.84     | 0.011 | +0.56  | 0.580   | No diff      |

---

## 5. Effect Size (Cohen's d)

Cohen's d measures practical significance:

- |d| < 0.2: negligible
- |d| < 0.5: small
- |d| < 0.8: medium
- |d| ≥ 0.8: large

### Formula

$$d = \frac{\bar{x}_1 - \bar{x}_2}{s_{pooled}}$$

### Results

| Metric | Battery (d) | Interpretation | AC (d) | Interpretation |
| ------ | ----------- | -------------- | ------ | -------------- |
| Power  | -1.01       | **LARGE**      | +0.05  | negligible     |
| CPU    | -0.71       | medium         | -0.08  | negligible     |
| Temp   | -0.92       | **LARGE**      | +0.58  | medium         |
| Load   | -0.52       | medium         | -0.10  | negligible     |

---

## 6. 95% Confidence Interval

### Battery Power Difference

```
CI = (x̄₁ - x̄₂) ± t_crit × SE_diff
CI = -2.56 ± 1.96 × 0.212
CI = [-2.98, -2.14]
```

**Interpretation:** With 95% confidence, XFCE uses between **2.14W and 2.98W less** power than Cinnamon on battery.

---

## 7. Summary Table

| Condition        | Significant? | XFCE Better | Cinnamon Better | Practical Significance |
| ---------------- | ------------ | ----------- | --------------- | ---------------------- |
| Battery - Light  | ✓ YES        | **-4.14W**  |                 | HIGH                   |
| Battery - Medium | ✓ YES        | **-4.65W**  |                 | HIGH                   |
| Battery - Heavy  | ✓ YES        | **-1.87W**  |                 | MEDIUM                 |
| Battery - Ultra  | ✓ YES        |             | -0.82W          | LOW                    |
| AC - Light       | ✗ NO         |             |                 | -                      |
| AC - Medium      | ✓ YES        |             | -0.06W          | NEGLIGIBLE             |
| AC - Heavy       | ✓ YES        |             | -0.02W          | NEGLIGIBLE             |
| AC - Ultra       | ✗ NO         |             |                 | -                      |

---

## 8. Conclusion

### Statistical Conclusion

- **On Battery:** XFCE is statistically significantly better for Light, Medium, and Heavy tasks (p < 0.001)
- **On AC:** No practically significant difference (< 0.1W)

### Practical Recommendation

> For laptop users prioritizing battery life, **XFCE is the better choice**.
> Savings of 2-5W during typical use translates to **15-30 minutes extra battery life**.

---

## Appendix: Raw Data Locations

- XFCE results: `benchmark_results/XFCE_full_20260127_190920/raw_metrics.csv`
- Cinnamon results: `benchmark_results/Cinnamon_full_20260127_193535/raw_metrics.csv`
- Comparison graphs: `benchmark_results/comparison/`
