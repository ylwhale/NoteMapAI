import Foundation
import Testing
@testable import MindMapAI

@MainActor
struct OpenAISynthesisContractTests {
    @Test("Grounded facts can be combined with generated planning guidance")
    func synthesizedQuizPlanIsAccepted() throws {
        let source = quizSource()
        let payload = """
        {
          "answer_parts": [
            {
              "kind": "source_fact",
              "text": "Review chapters 4 and 5 before Friday for the online quiz.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]
            },
            {
              "kind": "generated_guidance",
              "text": "Build the quiz plan around that review and deadline.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]
            }
          ],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [
            {"kind":"source_action","text":"Review chapters 4 and 5 before Friday for the online quiz.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Break chapters 4 and 5 into separate review sessions.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Start reviewing chapter 4 in a focused session.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Complete a practice check before Friday.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Check your progress before Friday.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]}
          ],
          "assumption": ""
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(payload.utf8),
            sources: [source],
            question: "Help me create a plan for the online quiz."
        )

        #expect(conclusion.directAnswer == "Review chapters 4 and 5 before Friday for the online quiz. Build the quiz plan around that review and deadline.")
        #expect(conclusion.answerEvidence.map(\.sourceNoteID) == [source.noteID])
        #expect(conclusion.answerParts?.map(\.origin) == [.sourceBacked, .generatedGuidance])
        #expect(conclusion.answerParts?.map(\.text) == [
            "Review chapters 4 and 5 before Friday for the online quiz.",
            "Build the quiz plan around that review and deadline."
        ])
        #expect(conclusion.answerParts?.flatMap(\.evidence).allSatisfy {
            $0.sourceNoteID == source.noteID
                && $0.quote == "Review chapters 4 and 5 before Friday for the online quiz."
        } == true)
        #expect(conclusion.suggestedChecklist.map(\.text) == [
            "Review chapters 4 and 5 before Friday for the online quiz.",
            "Break chapters 4 and 5 into separate review sessions.",
            "Start reviewing chapter 4 in a focused session.",
            "Complete a practice check before Friday.",
            "Check your progress before Friday."
        ])
        #expect(conclusion.suggestedChecklist.map(\.origin) == [
            .sourceBacked,
            .generatedGuidance,
            .generatedGuidance,
            .generatedGuidance,
            .generatedGuidance
        ])
        #expect(conclusion.suggestedChecklist.flatMap { $0.evidence ?? [] }.allSatisfy {
            $0.sourceNoteID == source.noteID
                && $0.quote == "Review chapters 4 and 5 before Friday for the online quiz."
        } == true)
    }

    @Test("Generated guidance cannot smuggle invented concrete facts")
    func inventedPlanningDetailsAreRejected() throws {
        let source = quizSource()
        let payload = """
        {
          "answer_parts": [
            {
              "kind": "source_fact",
              "text": "Review chapters 4 and 5 before Friday for the online quiz.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]
            },
            {
              "kind": "generated_guidance",
              "text": "Build the quiz plan around that review and deadline.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]
            },
            {
              "kind": "generated_guidance",
              "text": "Plan for the quiz to close on thursday.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]
            }
          ],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [
            {"kind":"generated_guidance","text":"Schedule chapter 6 before Thursday.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Schedule chapter six before friday.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Check your progress before Friday.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]}
          ],
          "assumption": ""
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(payload.utf8),
            sources: [source],
            question: "Help me create a plan for the online quiz."
        )

        #expect(!conclusion.directAnswer.localizedCaseInsensitiveContains("thursday"))
        #expect(!conclusion.suggestedChecklist.contains {
            $0.text.localizedCaseInsensitiveContains("chapter 6")
                || $0.text.localizedCaseInsensitiveContains("chapter six")
        })
        #expect(conclusion.suggestedChecklist.map(\.text) == ["Check your progress before Friday."])
    }

    @Test("Generated labels do not bypass entity relationship or certainty checks")
    func generatedLabelCannotHideAFactualClaim() throws {
        let source = SourceReference(
            noteID: UUID(),
            noteTitle: "Bookings",
            noteDate: .now,
            excerpt: "Alice booked Hilton. Bob booked Marriott.",
            score: 1,
            supportType: .exactText
        )
        let payload = """
        {
          "answer_parts": [
            {
              "kind": "source_fact",
              "text": "Alice booked Hilton.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Alice booked Hilton."}]
            },
            {
              "kind": "generated_guidance",
              "text": "List Marriott for Alice.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Alice booked Hilton. Bob booked Marriott."}]
            },
            {
              "kind": "generated_guidance",
              "text": "Consider that Hilton is free.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Alice booked Hilton."}]
            }
          ],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [],
          "assumption": ""
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(payload.utf8),
            sources: [source],
            question: "Summarize the bookings and make a plan."
        )

        #expect(conclusion.directAnswer == "Alice booked Hilton.")
        #expect(!conclusion.directAnswer.contains("free"))
        #expect(!conclusion.directAnswer.contains("Marriott for Alice"))
    }

    @Test("A valid generated checklist survives an invalid answer part")
    func validPlanStepsSurviveInvalidAnswer() throws {
        let source = quizSource()
        let payload = """
        {
          "answer_parts": [
            {
              "kind": "generated_guidance",
              "text": "Plan for the quiz to close on thursday.",
              "evidence": [{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]
            }
          ],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [
            {"kind":"generated_guidance","text":"Start reviewing chapter 4 in a focused session.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]},
            {"kind":"generated_guidance","text":"Check your progress before Friday.","source_ids":["\(source.noteID.uuidString)"],"evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"Review chapters 4 and 5 before Friday for the online quiz."}]}
          ],
          "assumption": ""
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(payload.utf8),
            sources: [source],
            question: "Help me create a plan for the online quiz."
        )

        #expect(conclusion.directAnswer == "Here is a practical plan based on your retrieved notes.")
        #expect(conclusion.answerEvidence.map(\.sourceNoteID) == [source.noteID])
        #expect(conclusion.suggestedChecklist.map(\.text) == [
            "Start reviewing chapter 4 in a focused session.",
            "Check your progress before Friday."
        ])
        #expect(conclusion.answerParts?.map(\.origin) == [.generatedGuidance])
    }

    @Test("Checklist provenance requires exact quotes from every declared known source")
    func checklistEvidenceIsExactAndSourceBound() throws {
        let source = quizSource()
        let otherSource = SourceReference(
            noteID: UUID(),
            noteTitle: "Other course",
            noteDate: .now,
            excerpt: "Read chapter 9 next month.",
            score: 0.8,
            supportType: .related
        )
        let quote = "Review chapters 4 and 5 before Friday for the online quiz."
        let payload = """
        {
          "answer_parts": [
            {
              "kind":"source_fact",
              "text":"Review chapters 4 and 5 before Friday for the online quiz.",
              "evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"\(quote)"}]
            }
          ],
          "claims": [],
          "conflicts": [],
          "missing_information": [],
          "checklist": [
            {
              "kind":"source_action",
              "text":"Review chapters 4 and 5 before Friday for the online quiz.",
              "source_ids":["\(source.noteID.uuidString)"],
              "evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"\(quote)"}]
            },
            {
              "kind":"generated_guidance",
              "text":"Check your progress before Friday.",
              "source_ids":["\(source.noteID.uuidString)"],
              "evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"\(quote)"}]
            },
            {
              "kind":"source_action",
              "text":"Review chapters 4 and 5 before Friday for the online quiz.",
              "source_ids":["\(source.noteID.uuidString)"],
              "evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"This quote was invented."}]
            },
            {
              "kind":"source_action",
              "text":"Review chapters 4 and 5 before Friday for the online quiz.",
              "source_ids":["\(source.noteID.uuidString)"],
              "evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"review chapters 4 and 5 before Friday for the online quiz."}]
            },
            {
              "kind":"generated_guidance",
              "text":"Check your progress before Friday.",
              "source_ids":["\(otherSource.noteID.uuidString)"],
              "evidence":[{"source_id":"\(source.noteID.uuidString)","quote":"\(quote)"}]
            }
          ],
          "assumption":""
        }
        """

        let conclusion = try GroundingValidator.validatedConclusion(
            from: Data(payload.utf8),
            sources: [source, otherSource],
            question: "Help me create a quiz plan."
        )

        #expect(conclusion.suggestedChecklist.map(\.origin) == [
            .sourceBacked,
            .generatedGuidance
        ])
        #expect(conclusion.suggestedChecklist.flatMap { $0.evidence ?? [] }.map(\.quote) == [
            quote,
            quote
        ])
    }

    @Test("Legacy conclusions decode without answer-part provenance")
    func legacyConclusionDecodingRemainsCompatible() throws {
        let payload = #"{"directAnswer":"Legacy grounded answer.","answerEvidence":[],"claims":[],"conflicts":[],"missingInformation":[],"suggestedChecklist":[],"statedAssumption":""}"#

        let conclusion = try JSONDecoder().decode(
            GroundedConclusion.self,
            from: Data(payload.utf8)
        )

        #expect(conclusion.answerParts == nil)
        #expect(conclusion.resolvedAnswerParts.map(\.text) == ["Legacy grounded answer."])
        #expect(conclusion.resolvedAnswerParts.map(\.origin) == [.sourceBacked])

        let legacyStep = try JSONDecoder().decode(
            SuggestedPlanItem.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000002","text":"Legacy step","sourceNoteIDs":[]}"#.utf8)
        )
        #expect(legacyStep.origin == nil)
        #expect(legacyStep.evidence == nil)
    }

    private func quizSource() -> SourceReference {
        SourceReference(
            noteID: UUID(),
            noteTitle: "Online quiz",
            noteDate: .now,
            excerpt: "Review chapters 4 and 5 before Friday for the online quiz.",
            score: 1,
            supportType: .exactText
        )
    }
}
