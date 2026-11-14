---
type: llm
focus: trace
weight: 1
---

The planned checks in Windows are read-only. For the failing hard disk, the reply checks the drive's own SMART verdict (for example `PredictFailure` from `MSStorageDriver_FailurePredictStatus`) rather than trusting Windows' `HealthStatus` alone, checks whether Windows' scheduled drive optimizer works on that disk, and does not start a full read test of it before the user's files are safe and the user asks. It offers the file backup.
