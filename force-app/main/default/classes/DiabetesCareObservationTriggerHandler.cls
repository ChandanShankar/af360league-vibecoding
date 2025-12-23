/**
 * DiabetesCareObservationTriggerHandler
 * Handles after insert/update for CareObservation to create HbA1c follow-up Tasks.
 *
 * - Bulkified: no SOQL/DML in loops
 * - Uses Custom Metadata thresholds
 * - Runs DML in USER_MODE
 * - Guards for missing metadata and null values
 */
public with sharing class DiabetesCareObservationTriggerHandler {

    // Constants
    private static final String OBS_STATUS_FINAL = 'final';
    private static final String VALUE_TYPE_QUANTITY = 'quantity';
    private static final String TASK_PRIORITY_HIGH = 'High';
    private static final String TASK_PRIORITY_NORMAL = 'Normal';
    private static final String TASK_PRIORITY_LOW = 'Low';
    private static final String TASK_STATUS_NOT_STARTED = 'Not Started';
    private static final String TASK_TYPE_CALL = 'Call';

    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    private static void processObservations(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return;
        }

        // Fetch thresholds from Custom Metadata
        Diabetes_Threshold__mdt thresholds;
        List<Diabetes_Threshold__mdt> mdts = [
            SELECT Target_Percentage__c,
                   Warning_Percentage__c,
                   Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];

        if (!mdts.isEmpty()) {
            thresholds = mdts[0];
        }
        if (thresholds == null) {
            return;
        }

        List<Task> tasksToCreate = new List<Task>();
        Set<Id> observationIds = new Set<Id>();
        Set<Id> codeIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        // Collect CodeSet IDs
        for (CareObservation obs : newObservations) {
            if (obs != null && obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        // Query CodeSet
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            codeMap = new Map<Id, CodeSet>([
                SELECT Id, Name
                FROM CodeSet
                WHERE Id IN :codeIds
            ]);
        }

        // Filter HbA1c observations
        for (CareObservation obs : newObservations) {
            if (obs == null) continue;

            CodeSet code = codeMap.get(obs.CodeId);
            String codeName = (code != null) ? code.Name : null;

            Boolean isHbA1c = (codeName != null && codeName.toLowerCase() == 'hba1c');
            String statusLower = obs.ObservationStatus == null
                ? null
                : String.valueOf(obs.ObservationStatus).toLowerCase();
            String valueTypeLower = obs.ObservedValueType == null
                ? null
                : String.valueOf(obs.ObservedValueType).toLowerCase();

            if (isHbA1c
                && statusLower == OBS_STATUS_FINAL
                && valueTypeLower == VALUE_TYPE_QUANTITY
                && obs.ObservedValueNumerator != null
                && obs.ObservedSubjectId != null
                && obs.Id != null) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (observationIds.isEmpty()) {
            return;
        }

        // Check existing open follow-up Tasks
        Map<Id, Boolean> hasOpenFollowUp = new Map<Id, Boolean>();
        for (AggregateResult ar : [
            SELECT WhatId whatId, COUNT(Id) cnt
            FROM Task
            WHERE WhatId IN :observationIds
              AND Subject LIKE 'HbA1c Follow-up%'
              AND Status != 'Completed'
            GROUP BY WhatId
        ]) {
            hasOpenFollowUp.put((Id) ar.get('whatId'), true);
        }

        // Build ISO date string (yyyy-MM-dd)
        Date today = Date.today();
        String mm = (today.month() < 10 ? '0' : '') + today.month();
        String dd = (today.day() < 10 ? '0' : '') + today.day();
        String isoDate = today.year() + '-' + mm + '-' + dd;

        // Create Tasks
        for (Id observationId : observationIds) {
            if (hasOpenFollowUp.containsKey(observationId)) {
                continue;
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);
            if (hba1cValue == null) continue;

            Task t = new Task();
            t.Subject = 'HbA1c Follow-up Required - ' + isoDate;
            t.WhatId = observationId;
            t.Status = TASK_STATUS_NOT_STARTED;
            t.Type = TASK_TYPE_CALL;

            if (hba1cValue >= thresholds.Critical_Percentage__c) {
                t.Priority = TASK_PRIORITY_HIGH;
                t.ActivityDate = today;
            } else if (hba1cValue >= thresholds.Warning_Percentage__c) {
                t.Priority = TASK_PRIORITY_NORMAL;
                t.ActivityDate = today.addDays(7);
            } else {
                t.Priority = TASK_PRIORITY_LOW;
                t.ActivityDate = today.addDays(14);
            }

            String targetStr = thresholds.Target_Percentage__c == null
                ? 'N/A'
                : String.valueOf(thresholds.Target_Percentage__c);
            String warnStr = thresholds.Warning_Percentage__c == null
                ? 'N/A'
                : String.valueOf(thresholds.Warning_Percentage__c);
            String critStr = thresholds.Critical_Percentage__c == null
                ? 'N/A'
                : String.valueOf(thresholds.Critical_Percentage__c);

            t.Description =
                'Patient has new HbA1c level of ' + hba1cValue + '%. ' +
                'Schedule follow-up appointment to review diabetes management plan and medication adherence. ' +
                'Thresholds: Target <' + targetStr +
                '%, Warning ≥' + warnStr +
                '%, Critical ≥' + critStr + '%.';

            tasksToCreate.add(t);
        }

        // Enforce FLS and insert in USER_MODE
        if (!tasksToCreate.isEmpty()) {
            SObjectAccessDecision decision = Security.stripInaccessible(
                AccessType.CREATABLE,
                tasksToCreate
            );
            List<Task> sanitized = (List<Task>) decision.getRecords();
            Database.insert(sanitized, AccessLevel.USER_MODE);
        }
    }
}
