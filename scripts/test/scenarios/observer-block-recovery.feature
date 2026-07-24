# QA procedure: an observer BLOCK must produce a SECOND, different candidate
# that then APPROVEs — never a rubber-stamped resubmission.
Scenario: observer BLOCK returns work to implement and a fixed candidate lands
  Given a throwaway node project with a red test
  And the claude stub in mode "block-then-approve"
  When the engine runs with the spec
  Then the archived run status is "complete"
  And the archived journal contains event "observer_verdict" with status "BLOCK"
  And the archived journal contains event "observer_verdict" with status "APPROVE"
  And the project file "add.js" contains "observer fix"
