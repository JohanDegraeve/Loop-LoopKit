original from https://github.com/LoopKit/Loop , latest sync 01e8aa3573c4dd309f60e8f64ff407cdd4317e21

personal changes :

- don't show red warning when notifications is not enabled for the app
- don't break the loop when manual temp basal is set
- bolusPartialApplicationFactor = 1.0
- don't use retrospectiveGlucoseEffect : this may create unexpected/dangerous microbolusses
- don't use positive glucoseMomentumEffect : this may create unexpected/dangerous microbolusses
- Temp basal rate when actual value is below average correction, full description in this commit message : https://github.com/JohanDegraeve/Loop-LoopKit/commit/d1247354abf4e436639231e6bddc9dfe1fafebff
- loop may run every 1.5 minute, iso of just every 5 minutes. This is ok because bolusPartialApplicationFactor = 1.0
