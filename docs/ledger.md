# The ledger

`ledger.tsv` is the record of the ladder this work climbs. It has one row for each number a rung
set out to move.

## Two ways of reading it

A rung is one change to the run of the rung before. It is judged by one comparison: the number it
set out to move, `before` against `after`, taken the same way on the same machine. That is the
tactical view, and it is the only one that passes or fails a rung. During development a rung
does not fail for being far from the end.

The `end` column holds the value the finished work asks of that number. It is not a gate. It is
there so that the rows, read together, are a map: which numbers have reached their end, which
have moved and by how much, and which nothing has touched yet. That is the strategic view. It is
read from the whole file and not from one row.

## The columns

| Column | Content |
| --- | --- |
| `rung` | the rung's number in the plan's order; rungs are climbed in that order and none is skipped |
| `date` | the day the rung passed here |
| `change` | the one thing that was changed |
| `number` | what was measured, and on what |
| `before` | its value on the rung below |
| `after` | its value on this rung |
| `end` | the value the exit asks for, where there is one |
| `note` | the gate that printed it and what the value depends on |

Times in this file are of the interpreted tier on one macOS arm64 machine. They can be compared
with each other and with nothing else.

## A planted defect

Every rung keeps its controls. A control is a planted defect that must make the rung's number
worse, and must be named by the gate. A rung whose number improved while a control went
unnoticed has not passed.
