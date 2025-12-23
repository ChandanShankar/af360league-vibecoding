/**
 * Apex class for assessing diabetes care based on HbA1c values and program enrollment.
 *
 * Overview:
 * - Invocable from Flow and other automation tools.
 * - Retrieves latest HbA1c (CareObservation) for patients and checks Diabetes program enrollment.
 * - Categorizes risk based on HbA1c value thresholds.
 *
 * Security:
 * - with sharing to respect sharing rules.
 * - Uses WITH USER_MODE where applicable patterns are allowed in SOQL (documented where not supported).
 *
 * Bulkification:
 * - Processes lists of requests.
 * - Performs selective SOQL outside loops.
 *
 * Error Handling:
 * - System-level and patient-level error handling with descriptive messages.
 *
 * Objects:
 * - CodeSet, CareObservation, CareProgram, CareProgramEnrollee
 */
public with sharing class DiabetesCareAssessment {

    /**
     * Input wrapper for invocable method.
     */
    public class AssessmentRequest {
        @InvocableVariable(required=true label='Patient Id' description='The Salesforce Id of the Patient/Account to assess')
        public Id patientId;
        @InvocableVariable(label='Days Lookback' description='Number of days to look back for observations (currently not used)')
        public Integer daysLookback;

        public AssessmentRequest() {}
        public AssessmentRequest(Id patientId, Integer daysLookback) {
            this.patientId = patientId;
            this.daysLookback = daysLookback;
        }
    }

    /**
     * Output wrapper for invocable method.
     */
    public class AssessmentResult {
        @InvocableVariable(label='Patient Id' description='The Salesforce Id of the Patient that was assessed')
        public Id patientId;
        @InvocableVariable(label='HbA1c Value' description='Latest HbA1c numeric value found for the patient (null if none)')
        public Decimal hba1cValue;
        @InvocableVariable(label='Risk Category' description='Risk category derived from HbA1c value')
        public String riskCategory;
        @InvocableVariable(label='Is In Diabetes Program' description='Indicates if the patient is enrolled in an active Diabetes care program')
        public Boolean isInDiabetesProgram;
        @InvocableVariable(label='Error Message' description='Error message if processing failed for this patient; null if successful')
        public String errorMessage;

        public AssessmentResult() {}
        public AssessmentResult(Id patientId) {
            this.patientId = patientId;
            this.isInDiabetesProgram = false;
        }
    }

    /**
     * Invocable entry point to assess patients.
     * Returns one AssessmentResult per request/patient.
     */
    @InvocableMethod(label='Assess Patient' description='Assesses patient diabetes care based on HbA1c values and program enrollment')
    public static List<AssessmentResult> assessPatient(List<AssessmentRequest> requests) {
        List<AssessmentResult> results = new List<AssessmentResult>();

        // 1) Input validation
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        // 2) Extract patient Ids and map back to request
        Set<Id> patientIds = new Set<Id>();
        Map<Id, AssessmentRequest> requestByPatient = new Map<Id, AssessmentRequest>();
        for (AssessmentRequest req : requests) {
            if (req != null && req.patientId != null) {
                patientIds.add(req.patientId);
                requestByPatient.put(req.patientId, req);
            }
        }

        if (patientIds.isEmpty()) {
            return results;
        }

        // 3) Lookup HbA1c CodeSet
        Id hba1cCodeSetId = getHbA1cCodeSetId();
        if (hba1cCodeSetId == null) {
            // HbA1c CodeSet not found - create error results for each patient and return early
            for (Id pid : patientIds) {
                AssessmentResult ar = new AssessmentResult(pid);
                ar.errorMessage = 'HbA1c CodeSet not found in the system';
                ar.riskCategory = 'No Data Available';
                ar.isInDiabetesProgram = false;
                results.add(ar);
            }
            return results;
        }

        // 4) Data retrieval - observations and program enrollment
        Map<Id, CareObservation> latestByPatient = getLatestHbA1cObservations(patientIds, hba1cCodeSetId);
        Map<Id, Boolean> inProgramByPatient = checkActiveDiabetesPrograms(patientIds);

        // 5) Process results
        for (Id pid : patientIds) {
            AssessmentResult res = new AssessmentResult(pid);
            try {
                CareObservation obs = latestByPatient.get(pid);
                if (obs != null && obs.ObservedValueNumerator != null) {
                    res.hba1cValue = obs.ObservedValueNumerator;

                    // Risk categorization
                    if (res.hba1cValue < 7.0) {
                        res.riskCategory = 'Well Controlled';
                    } else if (res.hba1cValue >= 7.0 && res.hba1cValue < 9.0) {
                        res.riskCategory = 'Needs Attention';
                    } else if (res.hba1cValue >= 9.0) {
                        res.riskCategory = 'High Risk/Urgent';
                    }
                } else {
                    res.riskCategory = 'No Data Available';
                }

                // Program enrollment
                res.isInDiabetesProgram = inProgramByPatient.containsKey(pid) ? inProgramByPatient.get(pid) : false;

            } catch (Exception ex) {
                res.errorMessage = 'Error processing patient ' + String.valueOf(pid) + ': ' + ex.getMessage();
            }
            results.add(res);
        }

        // 6) Return
        return results;
    }

    /**
     * Retrieves the Id of the CodeSet record named 'HbA1c'.
     * Returns null if not found.
     */
    private static Id getHbA1cCodeSetId() {
        // WITH USER_MODE is not supported in inline SOQL; use sharing covers record visibility.
        List<CodeSet> cs = [
            SELECT Id
            FROM CodeSet
            WHERE Name = 'HbA1c'
            LIMIT 1
        ];
        return cs.isEmpty() ? null : cs[0].Id;
    }

    /**
     * Retrieves most recent HbA1c CareObservation for each patient.
     * Returns a map of Patient Id -> Latest CareObservation.
     */
    private static Map<Id, CareObservation> getLatestHbA1cObservations(Set<Id> patientIds, Id hba1cCodeSetId) {
        Map<Id, CareObservation> latest = new Map<Id, CareObservation>();
        if (patientIds == null || patientIds.isEmpty() || hba1cCodeSetId == null) {
            return latest;
        }

        // Query ordered by EffectiveDateTime desc to take first per patient
        List<CareObservation> obsList = [
            SELECT Id, ObservedSubjectId, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE CodeId = :hba1cCodeSetId
              AND ObservedSubjectId IN :patientIds
              AND ObservationStatus = 'Final'
              AND ObservedValueType = 'Quantity'
              AND ObservedValueNumerator != null
            ORDER BY EffectiveDateTime DESC NULLS LAST
            LIMIT 1000
        ];

        for (CareObservation obs : obsList) {
            if (obs.ObservedSubjectId != null && !latest.containsKey(obs.ObservedSubjectId)) {
                latest.put(obs.ObservedSubjectId, obs);
            }
        }
        return latest;
    }

    /**
     * Determines enrollment in active Diabetes care programs.
     * Returns a map of Patient Id -> Boolean (true if enrolled).
     */
    private static Map<Id, Boolean> checkActiveDiabetesPrograms(Set<Id> patientIds) {
        Map<Id, Boolean> enrolled = new Map<Id, Boolean>();
        if (patientIds == null || patientIds.isEmpty()) {
            return enrolled;
        }

        // Initialize defaults
        for (Id pid : patientIds) {
            enrolled.put(pid, false);
        }

        // Subquery to restrict to Diabetes programs by name
        List<CareProgramEnrollee> enrollees = [
            SELECT Id, CareProgramId, AccountId, Status
            FROM CareProgramEnrollee
            WHERE AccountId IN :patientIds
              AND Status = 'Active'
              AND CareProgramId IN (
                  SELECT Id FROM CareProgram WHERE Name LIKE '%Diabetes%'
              )
            LIMIT 50000
        ];

        for (CareProgramEnrollee e : enrollees) {
            if (e.AccountId != null) {
                enrolled.put(e.AccountId, true);
            }
        }
        return enrolled;
    }
}
