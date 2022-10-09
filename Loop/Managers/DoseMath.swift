//
//  DoseMath.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/8/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit


private enum InsulinCorrection {
    case inRange
    case aboveRange(min: GlucoseValue, correcting: GlucoseValue, minTarget: HKQuantity, units: Double)
    case entirelyBelowRange(min: GlucoseValue, minTarget: HKQuantity, units: Double)
    case suspend(min: GlucoseValue)
}

// basal rate ranges.

fileprivate let lowLimitRange0 = 120.0
fileprivate let highLimitRange0 = 160.0

/// basal rates for range 0 , ie 140 - 160
fileprivate let basalRatesForAutoBasalRange0 = [[0.37748736,0.3145728,0.3145728],[0.3145728,0.262144,0.262144],[0.25165824,0.2097152,0.1835008],[0.12582912,0.1048576,0.0786432],[0.0,0.0,0.0]]

fileprivate let highLimitRange1 = 180.0

/// basal rates for range 1 , ie 150 - 180
fileprivate let basalRatesForAutoBasalRange1 = [[0.589824,0.49152,0.49152],[0.49152,0.4096,0.4096],[0.393216,0.32768,0.28672],[0.196608,0.16384,0.12288],[0.0,0.0,0.0]]

fileprivate let highLimitRange2 = 200.0

/// basal rates for range 2 , ie 180 - 200
fileprivate let basalRatesForAutoBasalRange2 = [[0.73728,0.6144,0.6144],[0.6144,0.512,0.512],[0.49152,0.4096,0.3584],[0.24576,0.2048,0.1536],[0.0,0.0,0.0]]

fileprivate let highLimitRange3 = 220.0

/// basal rates for range 3 , ie 200 - 220
fileprivate let basalRatesForAutoBasalRange3 = [[0.9216,0.768,0.768],[0.768,0.64,0.64],[0.6144,0.512,0.448],[0.3072,0.256,0.192],[0.0,0.0,0.0]]

fileprivate let highLimitRange4 = 250.0

/// basal rates for range 4 , ie 220 - 250
fileprivate let basalRatesForAutoBasalRange4 = [[1.152,0.96,0.96],[0.96,0.8,0.8],[0.768,0.64,0.56],[0.384,0.32,0.24],[0.0,0.0,0.0]]

/// basal rates for range 5 , ie > 250
fileprivate let basalRatesForAutoBasalRange5 = [[1.44,1.2,1.2],[1.2,1.0,1.0],[0.96,0.8,0.7],[0.48,0.4,0.3],[0.0,0.0,0.0]]

/// to keep track if last temp basal was set by variable basal algorithm
fileprivate var lastTempBasalSetByAutoBasalAlgorithm = false

fileprivate func calculateIndexInRanges(glucoseTrend: GlucoseTrend) -> Int {
    switch glucoseTrend {
    case .flat:
        return 2
    case .up:
        return 1
    case .upUp, .upUpUp:
        return 0
    case .down:
        return 3
    case .downDown, .downDownDown:
        return 4
    }
}

extension InsulinCorrection {
    /// The delivery units for the correction
    private var units: Double {
        switch self {
        case .aboveRange(min: _, correcting: _, minTarget: _, units: let units):
            return units
        case .entirelyBelowRange(min: _, minTarget: _, units: let units):
            return units
        case .inRange, .suspend:
            return 0
        }
    }
    
    

    /// Determines the temp basal over `duration` needed to perform the correction.
    ///
    /// - Parameters:
    ///   - scheduledBasalRate: The scheduled basal rate at the time the correction is delivered
    ///   - maxBasalRate: The maximum allowed basal rate
    ///   - duration: The duration of the temporary basal
    ///   - rateRounder: The smallest fraction of a unit supported in basal delivery
    /// - Returns: A temp basal recommendation
    fileprivate func asTempBasal(
        scheduledBasalRate: Double,
        maxBasalRate: Double,
        duration: TimeInterval,
        rateRounder: ((Double) -> Double)?
    ) -> TempBasalRecommendation {
        var rate = units / (duration / TimeInterval(hours: 1))  // units/hour
        switch self {
        case .aboveRange, .inRange, .entirelyBelowRange:
            rate += scheduledBasalRate
        case .suspend:
            break
        }

        rate = Swift.min(maxBasalRate, Swift.max(0, rate))

        rate = rateRounder?(rate) ?? rate

        return TempBasalRecommendation(
            unitsPerHour: rate,
            duration: duration
        )
    }

    private var bolusRecommendationNotice: BolusRecommendationNotice? {
        switch self {
        case .suspend(min: let minimum):
            return .glucoseBelowSuspendThreshold(minGlucose: minimum)
        case .inRange:
            return .predictedGlucoseInRange
        case .entirelyBelowRange(min: let min, minTarget: _, units: _):
            return .allGlucoseBelowTarget(minGlucose: min)
        case .aboveRange(min: let min, correcting: _, minTarget: let target, units: let units):
            if units > 0 && min.quantity < target {
                return .predictedGlucoseBelowTarget(minGlucose: min)
            } else {
                return nil
            }
        }
    }

    /// Determines the bolus needed to perform the correction, subtracting any insulin already scheduled for
    ///  delivery, such as the remaining portion of an ongoing temp basal.
    ///
    /// - Parameters:
    ///   - pendingInsulin: The number of units expected to be delivered, but not yet reflected in the correction
    ///   - maxBolus: The maximum allowable bolus value in units
    ///   - volumeRounder: Method to round computed dose to deliverable volume
    /// - Returns: A bolus recommendation
    fileprivate func asManualBolus(
        pendingInsulin: Double,
        maxBolus: Double,
        volumeRounder: ((Double) -> Double)?
    ) -> ManualBolusRecommendation {
        var units = self.units - pendingInsulin
        units = Swift.min(maxBolus, Swift.max(0, units))
        units = volumeRounder?(units) ?? units

        return ManualBolusRecommendation(
            amount: units,
            pendingInsulin: pendingInsulin,
            notice: bolusRecommendationNotice
        )
    }
    
    /// Determines the bolus amount to perform a partial application correction
    ///
    /// - Parameters:
    ///   - partialApplicationFactor: The fraction of needed insulin to deliver now
    ///   - maxBolus: The maximum allowable bolus value in units
    ///   - volumeRounder: Method to round computed dose to deliverable volume
    /// - Returns: A bolus recommendation
    fileprivate func asPartialBolus(
        partialApplicationFactor: Double,
        maxBolusUnits: Double,
        volumeRounder: ((Double) -> Double)?
    ) -> Double {

        let partialDose = units * partialApplicationFactor

        return Swift.min(Swift.max(0, volumeRounder?(partialDose) ?? partialDose),maxBolusUnits)
    }
}


extension TempBasalRecommendation {
    /// Equates the recommended rate with another rate
    ///
    /// - Parameter unitsPerHour: The rate to compare
    /// - Returns: Whether the rates are equal within Double precision
    private func matchesRate(_ unitsPerHour: Double) -> Bool {
        return abs(self.unitsPerHour - unitsPerHour) < .ulpOfOne
    }

    /// Determines whether the recommendation is necessary given the current state of the pump
    ///
    /// - Parameters:
    ///   - date: The date the recommendation would be delivered
    ///   - scheduledBasalRate: The scheduled basal rate at `date`
    ///   - lastTempBasal: The previously set temp basal
    ///   - continuationInterval: The duration of time before an ongoing temp basal should be continued with a new command
    ///   - scheduledBasalRateMatchesPump: A flag describing whether `scheduledBasalRate` matches the scheduled basal rate of the pump.
    ///                                    If `false` and the recommendation matches `scheduledBasalRate`, the temp will be recommended
    ///                                    at the scheduled basal rate rather than recommending no temp.
    /// - Returns: A temp basal recommendation
    func ifNecessary(
        at date: Date,
        scheduledBasalRate: Double,
        lastTempBasal: DoseEntry?,
        continuationInterval: TimeInterval,
        scheduledBasalRateMatchesPump: Bool
    ) -> TempBasalRecommendation? {
        // Adjust behavior for the currently active temp basal
        if let lastTempBasal = lastTempBasal,
            lastTempBasal.type == .tempBasal,
            lastTempBasal.endDate > date
        {
            /// If the last temp basal has the same rate, and has more than `continuationInterval` of time remaining, don't set a new temp
            if matchesRate(lastTempBasal.unitsPerHour),
                lastTempBasal.endDate.timeIntervalSince(date) > continuationInterval {
                return nil
            } else if matchesRate(scheduledBasalRate), scheduledBasalRateMatchesPump {
                // If our new temp matches the scheduled rate of the pump, cancel the current temp
                return .cancel
            }
        } else if matchesRate(scheduledBasalRate), scheduledBasalRateMatchesPump {
            // If we recommend the in-progress scheduled basal rate of the pump, do nothing
            return nil
        }

        return self
    }
}

/// Computes a total insulin amount necessary to correct a glucose differential at a given sensitivity
///
/// - Parameters:
///   - fromValue: The starting glucose value
///   - toValue: The desired glucose value
///   - effectedSensitivity: The sensitivity, in glucose-per-insulin-unit
/// - Returns: The insulin correction in units
private func insulinCorrectionUnits(fromValue: Double, toValue: Double, effectedSensitivity: Double) -> Double? {
    guard effectedSensitivity > 0 else {
        return nil
    }

    let glucoseCorrection = fromValue - toValue

    return glucoseCorrection / effectedSensitivity
}

/// Computes a target glucose value for a correction, at a given time during the insulin effect duration
///
/// - Parameters:
///   - percentEffectDuration: The percent of time elapsed of the insulin effect duration
///   - minValue: The minimum (starting) target value
///   - maxValue: The maximum (eventual) target value
/// - Returns: A target value somewhere between the minimum and maximum
private func targetGlucoseValue(percentEffectDuration: Double, minValue: Double, maxValue: Double) -> Double {
    // The inflection point in time: before it we use minValue, after it we linearly blend from minValue to maxValue
    let useMinValueUntilPercent = 0.5

    guard percentEffectDuration > useMinValueUntilPercent else {
        return minValue
    }

    guard percentEffectDuration < 1 else {
        return maxValue
    }

    let slope = (maxValue - minValue) / (1 - useMinValueUntilPercent)
    return minValue + slope * (percentEffectDuration - useMinValueUntilPercent)
}


extension Collection where Element: GlucoseValue {

    /// For a collection of glucose prediction, determine the least amount of insulin delivered at
    /// `date` to correct the predicted glucose to the middle of `correctionRange` at the time of prediction.
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of glucose values used for correction
    ///   - date: The date the insulin correction is delivered
    ///   - suspendThreshold: The glucose value below which only suspension is returned
    ///   - sensitivity: The insulin sensitivity at the time of delivery
    ///   - model: The insulin effect model
    /// - Returns: A correction value in units, or nil if no correction needed
    private func insulinCorrection(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date,
        suspendThreshold: HKQuantity,
        sensitivity: HKQuantity,
        model: InsulinModel
    ) -> InsulinCorrection? {
        var minGlucose: GlucoseValue?
        var eventualGlucose: GlucoseValue?
        var correctingGlucose: GlucoseValue?
        var minCorrectionUnits: Double?

        // Only consider predictions within the model's effect duration
        let validDateRange = DateInterval(start: date, duration: model.effectDuration)

        let unit = correctionRange.unit
        let sensitivityValue = sensitivity.doubleValue(for: unit)
        let suspendThresholdValue = suspendThreshold.doubleValue(for: unit)

        // For each prediction above target, determine the amount of insulin necessary to correct glucose based on the modeled effectiveness of the insulin at that time
        for prediction in self {
            guard validDateRange.contains(prediction.startDate) else {
                continue
            }

            // If any predicted value is below the suspend threshold, return immediately
            guard prediction.quantity >= suspendThreshold else {
                return .suspend(min: prediction)
            }

            // Update range statistics
            if minGlucose == nil || prediction.quantity < minGlucose!.quantity {
                minGlucose = prediction
            }
            eventualGlucose = prediction

            let predictedGlucoseValue = prediction.quantity.doubleValue(for: unit)
            let time = prediction.startDate.timeIntervalSince(date)

            // Compute the target value as a function of time since the dose started
            let targetValue = targetGlucoseValue(
                percentEffectDuration: time / model.effectDuration,
                minValue: suspendThresholdValue, 
                maxValue: correctionRange.quantityRange(at: prediction.startDate).averageValue(for: unit)
            )

            // Compute the dose required to bring this prediction to target:
            // dose = (Glucose Δ) / (% effect × sensitivity)

            // For 0 <= time <= effectDelay, assume a small amount effected. This will result in large unit recommendation rather than no recommendation at all.
            let percentEffected = Swift.max(.ulpOfOne, 1 - model.percentEffectRemaining(at: time))
            let effectedSensitivity = percentEffected * sensitivityValue
            guard let correctionUnits = insulinCorrectionUnits(
                fromValue: predictedGlucoseValue,
                toValue: targetValue,
                effectedSensitivity: effectedSensitivity
            ), correctionUnits > 0 else {
                continue
            }

            // Update the correction only if we've found a new minimum
            guard minCorrectionUnits == nil || correctionUnits < minCorrectionUnits! else {
                continue
            }

            correctingGlucose = prediction
            minCorrectionUnits = correctionUnits
        }

        guard let eventual = eventualGlucose, let min = minGlucose else {
            return nil
        }

        // Choose either the minimum glucose or eventual glucose as the correction delta
        let minGlucoseTargets = correctionRange.quantityRange(at: min.startDate)
        let eventualGlucoseTargets = correctionRange.quantityRange(at: eventual.startDate)

        // Treat the mininum glucose when both are below range
        if min.quantity < minGlucoseTargets.lowerBound &&
            eventual.quantity < eventualGlucoseTargets.lowerBound
        {
            let time = min.startDate.timeIntervalSince(date)
            // For 0 <= time <= effectDelay, assume a small amount effected. This will result in large (negative) unit recommendation rather than no recommendation at all.
            let percentEffected = Swift.max(.ulpOfOne, 1 - model.percentEffectRemaining(at: time))

            guard let units = insulinCorrectionUnits(
                fromValue: min.quantity.doubleValue(for: unit),
                toValue: minGlucoseTargets.averageValue(for: unit),
                effectedSensitivity: sensitivityValue * percentEffected
            ) else {
                return nil
            }

            return .entirelyBelowRange(
                min: min,
                minTarget: minGlucoseTargets.lowerBound,
                units: units
            )
        } else if eventual.quantity > eventualGlucoseTargets.upperBound,
            let minCorrectionUnits = minCorrectionUnits, let correctingGlucose = correctingGlucose
        {
            return .aboveRange(
                min: min,
                correcting: correctingGlucose,
                minTarget: eventualGlucoseTargets.lowerBound,
                units: minCorrectionUnits
            )
        } else {
            return .inRange
        }
    }

    /// Recommends a temporary basal rate to conform a glucose prediction timeline to a correction range
    ///
    /// Returns nil if the normal scheduled basal, or active temporary basal, is sufficient.
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of correction ranges
    ///   - date: The date at which the temp basal would be scheduled, defaults to now
    ///   - suspendThreshold: A glucose value causing a recommendation of no insulin if any prediction falls below
    ///   - sensitivity: The schedule of insulin sensitivities
    ///   - model: The insulin absorption model
    ///   - basalRates: The schedule of basal rates
    ///   - maxBasalRate: The maximum allowed basal rate
    ///   - lastTempBasal: The previously set temp basal
    ///   - rateRounder: Closure that rounds recommendation to nearest supported rate. If nil, no rounding is performed
    ///   - isBasalRateScheduleOverrideActive: A flag describing whether a basal rate schedule override is in progress
    ///   - duration: The duration of the temporary basal
    ///   - continuationInterval: The duration of time before an ongoing temp basal should be continued with a new command
    /// - Returns: The recommended temporary basal rate and duration
    func recommendedTempBasal(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date = Date(),
        suspendThreshold: HKQuantity?,
        sensitivity: InsulinSensitivitySchedule,
        model: InsulinModel,
        basalRates: BasalRateSchedule,
        maxBasalRate: Double,
        lastTempBasal: DoseEntry?,
        rateRounder: ((Double) -> Double)? = nil,
        isBasalRateScheduleOverrideActive: Bool = false,
        duration: TimeInterval = .minutes(30),
        continuationInterval: TimeInterval = .minutes(11)
    ) -> TempBasalRecommendation? {
        let correction = self.insulinCorrection(
            to: correctionRange,
            at: date,
            suspendThreshold: suspendThreshold ?? correctionRange.quantityRange(at: date).lowerBound,
            sensitivity: sensitivity.quantity(at: date),
            model: model
        )

        let scheduledBasalRate = basalRates.value(at: date)
        var maxBasalRate = maxBasalRate

        // TODO: Allow `highBasalThreshold` to be a configurable setting
        if case .aboveRange(min: let min, correcting: _, minTarget: let highBasalThreshold, units: _)? = correction,
            min.quantity < highBasalThreshold
        {
            maxBasalRate = scheduledBasalRate
        }

        let temp = correction?.asTempBasal(
            scheduledBasalRate: scheduledBasalRate,
            maxBasalRate: maxBasalRate,
            duration: duration,
            rateRounder: rateRounder
        )

        return temp?.ifNecessary(
            at: date,
            scheduledBasalRate: scheduledBasalRate,
            lastTempBasal: lastTempBasal,
            continuationInterval: continuationInterval,
            scheduledBasalRateMatchesPump: !isBasalRateScheduleOverrideActive
        )
    }
    
    /// Recommends a dose suitable for automatic enactment. Uses boluses for high corrections, and temp basals for low corrections.
    ///
    /// Returns nil if the normal scheduled basal, or active temporary basal, is sufficient.
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of correction ranges
    ///   - date: The date at which the temp basal would be scheduled, defaults to now
    ///   - suspendThreshold: A glucose value causing a recommendation of no insulin if any prediction falls below
    ///   - sensitivity: The schedule of insulin sensitivities
    ///   - model: The insulin absorption model
    ///   - basalRates: The schedule of basal rates
    ///   - maxBasalRate: The maximum allowed basal rate
    ///   - lastTempBasal: The previously set temp basal
    ///   - rateRounder: Closure that rounds recommendation to nearest supported rate. If nil, no rounding is performed
    ///   - isBasalRateScheduleOverrideActive: A flag describing whether a basal rate schedule override is in progress
    ///   - duration: The duration of the temporary basal
    ///   - continuationInterval: The duration of time before an ongoing temp basal should be continued with a new command
    /// - Returns: The recommended dosing, or nil if no dose adjustment recommended
    func recommendedAutomaticDose(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date = Date(),
        suspendThreshold: HKQuantity?,
        sensitivity: InsulinSensitivitySchedule,
        model: InsulinModel,
        basalRates: BasalRateSchedule,
        maxAutomaticBolus: Double,
        partialApplicationFactor: Double,
        lastTempBasal: DoseEntry?,
        volumeRounder: ((Double) -> Double)? = nil,
        rateRounder: ((Double) -> Double)? = nil,
        isBasalRateScheduleOverrideActive: Bool = false,
        duration: TimeInterval = .minutes(30),
        continuationInterval: TimeInterval = .minutes(11)
    ) -> AutomaticDoseRecommendation? {
        
        var temp: TempBasalRecommendation? = nil
        
        // check if autobasal is enabled and less than maxDurationAutoBasal hours old
        if UserDefaults.standard.bool(forKey: "keyAutoBasalRunning"), let timeStampStartOfAutoBasal = UserDefaults.standard.object(forKey: "keyTimeStampStartOfAutoBasal") as? Date, let latestGlucoseTimeStamp = UserDefaults.standard.object(forKey: "keyForLatestGlucoseTimeStamp") as? Date, UserDefaults.standard.double(forKey: "keyForLatestGlucoseValue") > 0, let latestGlucoseTrend = GlucoseTrend(rawValue: UserDefaults.standard.integer(forKey: "keyForLatestGlucoseTrend")) {
            
            let timeSinceStart = abs(timeStampStartOfAutoBasal.timeIntervalSinceNow)
            
            let maxDurationAutoBasal = TimeInterval(hours: Double(UserDefaults.standard.integer(forKey: "keyForAutoBasalDurationInHours")))
            
            if timeSinceStart < maxDurationAutoBasal {

                if abs(latestGlucoseTimeStamp.timeIntervalSinceNow) < 600.0 {

                    // calculate index in ranges, is it first quarter, last querter, or in between
                    let indexInRanges:Int = {
                        if timeSinceStart < maxDurationAutoBasal*0.5 {return 0}
                        if timeSinceStart < maxDurationAutoBasal*0.75 {return 1}
                        return 2
                    }()
                    
                    // calculate index in trends
                    let indexInTrends = calculateIndexInRanges(glucoseTrend: latestGlucoseTrend)
                    
                    // read latest glucose value from userdefaults
                    let latestGlucoseValue = UserDefaults.standard.double(forKey: "keyForLatestGlucoseValue")
                    
                    // rate to use in temp basal, if nil then no temp basal to use
                    var rate:Double?
                    
                    if latestGlucoseValue < lowLimitRange0 {
                        // nothing to do, if there's still a temp running from previous check, then it will be canceled (see check 'if temp == nil && lastTempBasalSetByVariableBasalAlgorithm')
                    } else if latestGlucoseValue < highLimitRange0 {
                        rate = basalRatesForAutoBasalRange0[indexInTrends][indexInRanges]
                    } else if latestGlucoseValue < highLimitRange1 {
                        rate = basalRatesForAutoBasalRange1[indexInTrends][indexInRanges]
                    } else if latestGlucoseValue < highLimitRange2 {
                        rate = basalRatesForAutoBasalRange2[indexInTrends][indexInRanges]
                    } else if latestGlucoseValue < highLimitRange3 {
                        rate = basalRatesForAutoBasalRange3[indexInTrends][indexInRanges]
                    } else if latestGlucoseValue < highLimitRange4 {
                        rate = basalRatesForAutoBasalRange4[indexInTrends][indexInRanges]
                    } else {
                        rate = basalRatesForAutoBasalRange5[indexInTrends][indexInRanges]
                    }
                    
                    if let rate = rate {

                        // basal rate arrays are normalized values, with max 1 when trend is up and value higher than 250 - those rates wiill be multipled with autoBasalMultiplicationFactor
                        var rateToUse = rate * UserDefaults.standard.double(forKey: "keyAutoBasalMultiplier")
                        rateToUse = rateRounder?(rateToUse) ?? rateToUse

                        temp = TempBasalRecommendation(unitsPerHour: rateToUse, duration: duration)
                        
                        lastTempBasalSetByAutoBasalAlgorithm = true
                        
                    } else {

                        // if last temp basal was set by auto basal algo, but algo does not recommend any temp basal now, then cancel the lastest one
                        if temp == nil && lastTempBasalSetByAutoBasalAlgorithm {
                            
                            if let lastTempBasal = lastTempBasal, lastTempBasal.type == .tempBasal, lastTempBasal.endDate > date {
                                
                                temp = .cancel
                                
                            }
                        }

                    }
                    
                }

            } else {
                // UserDefaults.standard.object(forKey: "keyAutoBasalRunning") still true but it passed the max duration
                // let's set it to false
                UserDefaults.standard.set(false, forKey: "keyAutoBasalRunning")
                
            }
            
        }
        
        guard let correction = self.insulinCorrection(
            to: correctionRange,
            at: date,
            suspendThreshold: suspendThreshold ?? correctionRange.quantityRange(at: date).lowerBound,
            sensitivity: sensitivity.quantity(at: date),
            model: model
        ) else {
            return nil
        }

        let scheduledBasalRate = basalRates.value(at: date)
        var maxAutomaticBolus = maxAutomaticBolus

        if case .aboveRange(min: let min, correcting: _, minTarget: let doseThreshold, units: _) = correction,
            min.quantity < doseThreshold
        {
            maxAutomaticBolus = 0
        }

        // if no temp basal set yet by automatic basal, then calculate temp basal as done originally by Loop
        if temp == nil {
            temp = correction.asTempBasal(
                scheduledBasalRate: scheduledBasalRate,
                maxBasalRate: scheduledBasalRate,
                duration: duration,
                rateRounder: rateRounder
            )
        }

        temp = temp?.ifNecessary(
            at: date,
            scheduledBasalRate: scheduledBasalRate,
            lastTempBasal: lastTempBasal,
            continuationInterval: continuationInterval,
            scheduledBasalRateMatchesPump: !isBasalRateScheduleOverrideActive
        )

        let bolusUnits = correction.asPartialBolus(partialApplicationFactor: partialApplicationFactor, maxBolusUnits: maxAutomaticBolus, volumeRounder: volumeRounder)

        // if variable basal enabled in UserDefaults
        // if there's no bolusUnits and no temp basal recommended
        // if no tempbasal running at the moment
        // if there's no basal rate schedule override active
        // if manual temp basals are not added in glucose effect calculation
        // if latest reading is less than 10 minutes old
        //    then check if current value is below avarage in correction range, and if so set temp basal at x% of actual current basal rate
        if UserDefaults.standard.bool(forKey: "keyForUseVariableBasal") && temp == nil && bolusUnits == 0.0 && !isBasalRateScheduleOverrideActive {
            if (lastTempBasal != nil && lastTempBasal!.endDate < date) || lastTempBasal == nil {
                if let first = self.first, abs(first.startDate.timeIntervalSinceNow) < 600.0 {

                    // average  correction range at date
                    // not tested for mmol
                    let averagevalue = (correctionRange.value(at: date).maxValue  + correctionRange.value(at: date).minValue)/2
                    
                    if first.quantity.doubleValue(for: correctionRange.unit) < averagevalue {

                        temp = TempBasalRecommendation(unitsPerHour: basalRates.value(at: date) * Double(UserDefaults.standard.integer(forKey: "keyForPercentageVariableBasal"))/100.0, duration: duration)
                        
                        // automatic = false, is to avoid that normal Loop stops this type of temp basal
                        temp!.automatic = false
                        
                        
                    }
                }
            }
        }
        
        if temp != nil || bolusUnits > 0 {
            return AutomaticDoseRecommendation(basalAdjustment: temp, bolusUnits: bolusUnits)
        }

        return nil
    }


    /// Recommends a bolus to conform a glucose prediction timeline to a correction range
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of correction ranges
    ///   - date: The date at which the bolus would apply, defaults to now
    ///   - suspendThreshold: A glucose value causing a recommendation of no insulin if any prediction falls below
    ///   - sensitivity: The schedule of insulin sensitivities
    ///   - model: The insulin absorption model
    ///   - pendingInsulin: The number of units expected to be delivered, but not yet reflected in the correction
    ///   - maxBolus: The maximum bolus to return
    ///   - volumeRounder: Closure that rounds recommendation to nearest supported bolus volume. If nil, no rounding is performed
    /// - Returns: A bolus recommendation
    func recommendedManualBolus(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date = Date(),
        suspendThreshold: HKQuantity?,
        sensitivity: InsulinSensitivitySchedule,
        model: InsulinModel,
        pendingInsulin: Double,
        maxBolus: Double,
        volumeRounder: ((Double) -> Double)? = nil
    ) -> ManualBolusRecommendation {
        guard let correction = self.insulinCorrection(
            to: correctionRange,
            at: date,
            suspendThreshold: suspendThreshold ?? correctionRange.quantityRange(at: date).lowerBound,
            sensitivity: sensitivity.quantity(at: date),
            model: model
        ) else {
            return ManualBolusRecommendation(amount: 0, pendingInsulin: pendingInsulin)
        }

        var bolus = correction.asManualBolus(
            pendingInsulin: pendingInsulin,
            maxBolus: maxBolus,
            volumeRounder: volumeRounder
        )

        // Handle the "current BG below target" notice here
        // TODO: Don't assume in the future that the first item in the array is current BG
        if case .predictedGlucoseBelowTarget? = bolus.notice,
            let first = first, first.quantity < correctionRange.quantityRange(at: first.startDate).lowerBound
        {
            bolus.notice = .currentGlucoseBelowTarget(glucose: first)
        }

        return bolus
    }
}
