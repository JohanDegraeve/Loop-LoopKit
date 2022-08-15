original from https://github.com/LoopKit/Loop , latest sync 01e8aa3573c4dd309f60e8f64ff407cdd4317e21

personal changes :

- don't show red warning when notifications is not enabled for the app
- don't break the loop when manual temp basal is set
- bolusPartialApplicationFactor = 1.0
- don't use retrospectiveGlucoseEffect : this was created unexpected/dangerous microbolusses
- don't use positive glucoseMomentumEffect between 00:00 and 08:00, to be a bit less agressive in microbolussing during the night
- changed absorption times for medium and slow : fast: .minutes(30), medium: .hours(2), slow: .hours(3)
- Temp basal rate when actual value is below average correction, full description in this commit message : https://github.com/JohanDegraeve/Loop-LoopKit/commit/d1247354abf4e436639231e6bddc9dfe1fafebff
