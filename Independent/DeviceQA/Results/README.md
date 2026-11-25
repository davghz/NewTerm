# iPhone X comparison

These runs used the physical iPhone X on iOS 15.6.1 on November 24–25, 2026. Each case exercised a 46-column, 24-row region. The fixture measured elapsed time from writing terminal output to receiving a verified cursor-position report. Each build passed 41 reports per case, 246 in total. The baseline used alpha3 from a479ba7. The independent candidate included the batched ASCII parser from bce2a00. Both used isolated app identities. Baseline peak thermal states were nominal or fair and candidate peaks were fair.

The summary includes the median, 95th percentile, process CPU as a percentage of one core, and observed peak physical footprint. The samples file contains every measured cursor-report round trip. Output parsing, scheduling, and PTY response all contribute to these times. Separately, a physical software-keyboard test verified each local echo using a composed screenshot. XCTest and screenshot capture time are included in that observation.

[Matched summary](iphone-x-46x24.csv) · [Individual samples](iphone-x-46x24-samples.csv) · [Fixture and measurement instructions](../README.md)
