# Variant boards

Output of the variant board tool (execution-plan component 3, not built yet).
A board renders 3 to 6 options side by side from ONE seed so Alex can choose
quickly; the choice is recorded in `data/decisions/decisions.json` and reported
for the design doc's decision log.

Layout, one folder per decision:

```
variants/<decision-id>/
  board.json      the seed, the parameter set behind each option, and which was chosen
  board.png       the sheet as shown
  <option>.png    each option on its own, same seed
```

Boards are archived, not deleted, once a choice is made: the options that lost
are part of the record. Whether rendered sheets are committed or only their
`board.json` is open -- see the open questions in CLAUDE.md.
