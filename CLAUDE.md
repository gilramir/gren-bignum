# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## About this project

`gren-bigint` is a [Gren](https://gren-lang.org/) package providing
arbitrary-precision integers, plus the fixed-width views (`maskTo`,
`toSigned`, `fitsSigned`, `fitsUnsigned`) that let a program work in `uint64`
or `int32` without a separate numeric type. All library code is in
`src/BigInt.gren`. [README.md](README.md) says what it does and why.

## Commands

Everything runs inside devbox; `gren` and node 22 are not on `PATH` otherwise.

```sh
devbox run build    # compile the package
devbox run docs     # check the doc comments parse
devbox run test     # tests/run.sh: 67 checks, ~1s
```

Format sources after editing them, especially after scripted edits.

## The platform fact that governs the implementation

**Gren's `//` truncates its result to 32 bits.** It is `(a / b) | 0`
underneath, so `(2^48) // 2` is `0` and `(2^31) // 1` is `-2147483648`. What
has to fit in 32 bits is the *quotient*, not the operands.

Every `//` in `src/BigInt.gren` is on a quotient smaller than 2^25 by
construction — a carry out of a limb, a digit of the answer, an index. **That
is an invariant to preserve, not a coincidence.** Where a quotient can be
large, `Math.truncate (a / b)` is the one that is right at any size; `fromInt`
goes through `fromFloat` for exactly this reason.

`*`, `+`, `-` and `Math.modBy` are all fine at full double precision. It is
only `//`.

## Architecture

`src/BigInt.gren` is in four layers, in this order down the file:

1. **The type and conversions.** Sign and magnitude: a `Bool` and an array of
   24-bit limbs, little-endian, normalised so there are no leading zero limbs
   and zero is the empty array. Everything is built through `make`, which
   enforces that — which is what keeps `==` meaningful.
2. **Magnitudes** (`magAdd`, `magSub`, `mulByLimb`, `magMul`, `magDivMod`,
   the shifts). Bare limb arrays, no signs. `magMul` accumulates rows with
   `magAdd` rather than writing into a scratch buffer, which keeps it to
   sequential building on immutable arrays. `magDivMod` is Knuth's algorithm D
   with normalisation, so `correct` runs at most twice.
3. **Signed wrappers** — the arithmetic, comparison and the two divisions.
4. **Bits and widths.** `bitwise` converts both operands to two's complement in
   a field one limb wider than either, applies the operation limb by limb,
   and converts back. `complement` needs none of that: `~x` is `-x - 1`.

## Tests

`tests/` is a separate Gren application depending on this package through
`"local:../"`, run with `gilramir/gren-unit-node`. Four suites, and the split
matters:

- `Differential.gren` — the same sums twice, through `BigInt` and through
  `Int`. It can only judge answers an `Int` can hold, which is why the
  multiplication pairs are kept small and the boundary division is checked
  against `Math.truncate (a / b)` rather than `//`.
- `BigNumbers.gren` — past 2^53, against values from an independent
  implementation.
- `Bits.gren` — against Python, which defines these operations the same way.
- `Strings.gren` — round trips in every base, and the refusals.

When adding an operation, add it to the differential suite first: it is the one
that finds sign and zero bugs without anybody having to think of them.
