/// AI Hub tool the agent calls before deciding: "did this pharmacy ever dispense
/// the recalled product?" Read-only, returns counts only (no patient ids).
Class RecallReach.AI.PharmacyTools Extends %AI.Tool
{

Property Name As %String [ InitialExpression = "Pharmacy records" ];

Property Description As %String(MAXLEN = "") [ InitialExpression = "Read-only counts from this pharmacy's dispensing records. No patient identifiers." ];

/// Count fills and patients for the recalled NDCs and for the ingredient.
/// ndcs: NDCs exactly as printed in the notice, comma separated (e.g. "68084-060-11, 68084-060-01")
/// ingredient: active ingredient name (e.g. "Lisinopril")
/// Returns fills/patients per NDC, and the strengths of this ingredient that were dispensed.
ClassMethod LookupDispensed(ndcs As %String, ingredient As %String) As %DynamicObject
{
    Set out = {"ndcs": [], "ingredient": (ingredient), "ingredient_fills": 0, "ingredient_patients": 0, "strengths_dispensed": []}
    Try {
        For i = 1:1:$L(ndcs, ",") {
            Set raw = $ZSTRIP($P(ndcs, ",", i), "<>W")
            Continue:raw=""
            Set n = ..NDC11(raw)
            Set fills = 0, pats = 0
            If n '= "" {
                &sql(SELECT COUNT(*), COUNT(DISTINCT SubjectId) INTO :fills, :pats FROM RecallReach_Data.Dispense WHERE NDC = :n)
            }
            Do out.ndcs.%Push({"ndc": (raw), "ndc11": (n), "valid": (n'=""), "fills": (+fills), "patients": (+pats)})
        }
        // first word of the ingredient ("Amlodipine Besylate" -> "amlodipine") so salt names still match
        Set norm = $ZCVT($P($ZSTRIP(ingredient, "<>W"), " "), "L")
        If $L(norm) >= 4 {
            Set like = "%"_norm_"%"
            &sql(SELECT COUNT(*), COUNT(DISTINCT SubjectId) INTO :f, :p FROM RecallReach_Data.Dispense WHERE LOWER(Drug) LIKE :like)
            Set out."ingredient_fills" = +f, out."ingredient_patients" = +p
            Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 10 Strength, COUNT(*) AS n FROM RecallReach_Data.Dispense WHERE LOWER(Drug) LIKE ? GROUP BY Strength ORDER BY n DESC", like)
            While rs.%Next() { Do out."strengths_dispensed".%Push({"strength": (rs.%Get("Strength")), "fills": (rs.%Get("n"))}) }
        }
    } Catch ex {
        Return {"error": (ex.DisplayString())}
    }
    Return out
}

/// 4-4-2 / 5-3-2 / 5-4-1 / 5-4-2 -> 11 digits (ObjectScript twin of recallreach_core.ndc.to_11;
/// kept native because tool calls run inside the AI Hub callback)
ClassMethod NDC11(raw As %String) As %String [ Internal ]
{
    Set s = $ZSTRIP(raw, "<>W")
    If $L(s, "-") '= 3 Quit $S((s?11N):s, 1:"")
    Set a = $P(s, "-", 1), b = $P(s, "-", 2), c = $P(s, "-", 3)
    If '((a?1.N) && (b?1.N) && (c?1.N)) Quit ""
    Set shape = $L(a)_"-"_$L(b)_"-"_$L(c)
    If shape = "4-4-2" Quit "0"_a_b_c
    If shape = "5-3-2" Quit a_"0"_b_c
    If shape = "5-4-1" Quit a_b_"0"_c
    If shape = "5-4-2" Quit a_b_c
    Quit ""
}

}
