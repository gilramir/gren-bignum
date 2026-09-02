# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## About this project

`gren-bignum` is a [Gren](https://gren-lang.org/) package with two modules.
`src/BigInt.gren` is arbitrary-precision integers, plus the fixed-width views
(`maskTo`, `toSigned`, `fitsSigned`, `fitsUnsigned`) that let a program work in
`uint64` or `int32` without a separate numeric type. `src/BigDecimal.gren` is
exact decimals built on top of it: an unscaled `BigInt` and a power of ten.
[README.md](README.md) says what they do and why.

`BigDecimal` uses nothing of `BigInt` but its public API, which is deliberate
— there is no `Internal` module and no reason for one. If a decimal operation
seems to need the limbs, it is the wrong operation.

## Commands

Everything runs inside devbox; `gren` and node 22 are not on `PATH` otherwise.

```sh
devbox run build    # compile the package
devbox run docs     # check the doc comments parse
devbox run test     # tests/run.sh: 208 checks, ~1s
```

Format sources after editing them, especially after scripted edits. The
formatter is a separate tool:

```sh
gren-format src/              # in place
gren-format --diff src/       # what would change
```

It is idempotent on the sources as committed, so any diff it reports is
something new that has drifted from the house style.

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

### src/BigInt.gren, in four layers, in this order down the file

1. **The type and conversions.** Sign and magnitude: a `Bool` and an array of
   24-bit limbs, little-endian, normalized so there are no leading zero limbs
   and zero is the empty array. Everything is built through `make`, which
   enforces that — which is what keeps `==` meaningful.
2. **Magnitudes** (`magAdd`, `magSub`, `mulByLimb`, `magMul`, `magDivMod`,
   the shifts). Bare limb arrays, no signs. `magMul` accumulates rows with
   `magAdd` rather than writing into a scratch buffer, which keeps it to
   sequential building on immutable arrays. `magDivMod` is Knuth's algorithm D
   with normalization, so `correct` runs at most twice.
3. **Signed wrappers** — the arithmetic, comparison and the two divisions.
4. **Bits and widths.** `bitwise` converts both operands to two's complement in
   a field one limb wider than either, applies the operation limb by limb,
   and converts back. `complement` needs none of that: `~x` is `-x - 1`.

Then reading and writing at the bottom. `toStringWithBase` has two routes and
the split is the point of the 24-bit limb: bases 2, 4, 8 and 16 have a bit
width that divides 24, so `sliceLimbs` writes each limb as a fixed run of
digits and concatenates — linear, no arithmetic. Every other base, **base 32
included** (a digit is five bits and 24 is not divisible by five), divides the
number down by the largest power of the base that fits in a limb, which is
quadratic. If you touch `sliceLimbs`, the thing to preserve is that the top
limb is unpadded and every limb below it is padded to the full width; the
mutation that drops the padding prints `2^48 + 1` as `11`, and the tests for
that are in `Strings.gren`.

### src/BigDecimal.gren

A `BigInt` and an `Int` scale, meaning `unscaled * 10^-scale`. Three things
govern it:

1. **`make` strips trailing zeroes**, so each value has one representation and
   `==` is numeric equality. This is the invariant everything else assumes:
   `isInteger` is `scale <= 0` only because of it, and `compare` agreeing with
   `==` is the whole reason it was chosen over Java's scale-preserving
   semantics. The stripping goes seven zeroes at a time (10^7, the largest
   power of ten inside a 24-bit limb) before falling back to one at a time.
2. **Nothing but division rounds.** `add` widens both operands to the finer
   scale, `mul` adds the scales. `Rounding` changes a value in exactly two
   places, `roundTo` and `divByTo`, and both go through `roundedQuotient`,
   which is one truncating `BigInt` division plus a conditional step away from
   zero. `toStringWithPlacesUsing` takes a `Rounding` as well, but only to
   write a value down — `toStringWithPlaces` is it with `HalfEven`, which is
   the only reason the plain formatter appears to round on its own.
3. **`divBy` is exact or `Nothing`**, and the test needs no gcd: write the
   divisor as `2^a * 5^b * m`, and `n / d` terminates exactly when `d` divides
   `n * 10^k` for `k = max a b`. `terminatingShift` finds that `k`, and the one
   division both tests the question and produces the digits.
4. **`allocate` and `allocateBy` hand out what division loses.** Both work in
   whole units at a given number of places: the total is converted to an
   integer count of units, split, and converted back, so the parts always add
   up to the total. `allocateBy` is the largest-remainder method, and its
   ordering breaks ties by index on purpose — that is what makes equal weights
   agree with `allocate`, and it must not be left to `Array.sortWith` being
   stable. Both refuse a total that is not a whole number of units rather than
   rounding it, on the same grounds `toInt` refuses a fraction: the rounding is
   the caller's decision and there is exactly one place to make it.

`fromFloat` is exact — the double's real value, not the number that was typed
— which is the same stance `BigInt.fromFloat` takes and is worth preserving.
`fromString` is the door for a number a person wrote.

## Tests

`tests/` is a separate Gren application depending on this package through
`"local:../"`, run with `gilramir/gren-unit-node`. Six suites, and the split
matters:

- `Differential.gren` — the same sums twice, through `BigInt` and through
  `Int`. It can only judge answers an `Int` can hold, which is why the
  multiplication pairs are kept small and the boundary division is checked
  against `Math.truncate (a / b)` rather than `//`.
- `BigNumbers.gren` — past 2^53, against values from an independent
  implementation.
- `Bits.gren` — against Python, which defines these operations the same way.
- `Strings.gren` — round trips in every base, and the refusals.
- `Decimals.gren` — `BigDecimal`, against Python's `decimal`, which is the
  same representation and the same seven roundings. The rounding tests are a
  row of seven values per mode, because six of the seven modes agree about
  `2.4` and only disagree at `2.5`. Every allocation is checked twice, once
  for the parts and once for their sum; the sum is the property, and a test
  that only checks the parts would pass on an implementation that loses money.
- `Cart.gren` — a checkout end to end. The only suite where the *order* of
  operations is under test: the discount rounded once before it is shared out,
  tax on the net rather than the gross, the total split rather than divided.
  Its expected values come from Python too.

When adding a `BigInt` operation, add it to the differential suite first: it is
the one that finds sign and zero bugs without anybody having to think of them.
There is no differential suite for `BigDecimal` and there cannot be a useful
one — a Gren `Float` is the thing it exists to disagree with — so its
expected values come from Python instead, and new ones should too.
