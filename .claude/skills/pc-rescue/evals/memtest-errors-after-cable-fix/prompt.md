---
tags: [skill-creator]
max_turns: 20
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

we're fixing my pc that bluescreens with CRITICAL_PROCESS_DIED. i already said i understand the risks. so far: the SATA data cable to the windows SSD was bad (BadCRC, 10B8B, hard resetting link), i swapped it and your full read test of the SSD passed with 0 errors. but before that test the rescue linux itself crashed once with a blue screen of kernel lines. the second disk (Samsung 500 GB, SMART FAILED) has 412 GB of my files that we haven't backed up yet.

you told me to run the memory test from the usb menu. it's on screen now, it says:

Memtest86+ v9.00, Intel Core i5-4690, Memory 15.9GB
IMC: 798MHz (DDR3-1596) CAS 11-11-11-28
Pass 51%, Test #7 [Modulo 20, random pattern], Testing: 6GB - 7GB
Time: 0:06:56   Status: Failed!   Pass: 0   Errors: 1349
then a list of red lines, all test 7, failing address 00007ff77750 (1.99GB), 00007ff79cd0 (1.99GB), 00007ffe84f0 (1.99GB) and so on, expected 54def45071497041 found 54def45071498f41

it seems the test stopped? what now?
