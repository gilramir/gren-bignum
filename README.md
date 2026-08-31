# gren-bigint

Arbitrary-precision integers for [Gren](https://gren-lang.org), and the
fixed-width views of them that a programmer actually asks for.

```gren
import BigInt

BigInt.fromString "0xFFFFFFFFFFFFFFFF"
    |> Maybe.map BigInt.toString
    --> Just "18446744073709551615"
```

## Why

A Gren `Int` is a double. It is exact to 2^53 and quietly wrong above that,
which is fine until the day you are working out what a `uint64` did. Then it is
the whole problem: `2^64 - 1` comes back as `18446744073709552000`, and nothing
tells you that four digits went missing.

Division is worse, and it surprised this package into existence. Gren's `//`
compiles to `(a / b) | 0`, so it truncates its **result** to 32 bits:

```gren
281474976710656 // 2  --> 0          -- 2^48 / 2
2147483648 // 1       --> -2147483648  -- 2^31
```

The operands are fine at any size; it is the quotient that has to fit. So an
`Int` is not merely imprecise above 2^53 — above 2^31 it cannot be divided at
all.

## Widths, which is the interesting part

A `BigInt` has no width. What it has instead is a way to *ask* for one, so the
width is a question you put to a value rather than a property the value carries
and can silently break.

```gren
x |> BigInt.maskTo 64        -- as a uint64
x |> BigInt.toSigned 64      -- as an int64
x |> BigInt.fitsSigned 64    -- would it have overflowed?
```

`maskTo` wraps the way a register does, so `maskTo 64 (fromInt -1)` is
`18446744073709551615` and `toSigned 64` of that is `-1` again.

## What is in it

| | |
|---|---|
| arithmetic | `add` `subBy` `mul` `negate` `abs` `powBy` |
| division | `quotRemBy` truncating, `divModBy` flooring |
| bits | `and` `or` `xor` `complement` `shiftLeftBy` `shiftRightBy` `bitLength` `popCount` |
| widths | `maskTo` `toSigned` `fitsSigned` `fitsUnsigned` |
| text | `fromString` `toString`, and the same with a base from 2 to 36 |
| numbers | `fromInt` `toInt` `fromFloat` `toFloat` |

**Both divisions, because a programmer gets asked both.** `quotRemBy` truncates
toward zero and its remainder takes the dividend's sign, which is C. `divModBy`
floors and its modulus takes the divisor's sign, which is Python. `-7 / 2` is
`-3` remainder `-1` in one and `-4` modulus `1` in the other. Neither is more
correct; which you want depends on which language you are checking.

**The bitwise operations read a value as two's complement of unbounded width**,
so `complement (fromInt 5)` is `-6` and `and (fromInt -6) (fromInt 3)` is `2` —
the same answers Python gives, and the only ones available when nobody has
declared how wide the number is. `shiftRightBy` is arithmetic: it floors, so
`-1` shifted right stays `-1`.

**Strings carry a sign, not a two's complement.** `toStringWithBase 16
(fromInt -255)` is `"-ff"`. For a machine's rendering of a 64-bit value,
`maskTo 64` first — which is what that function is for. `fromString` takes
`0x`, `0b` and `0o` prefixes, either case, either sign, and ignores underscores,
so `0xdead_beef` parses. Anything it does not understand is `Nothing` rather
than zero.

## Argument order

The operations where order matters take their subject **last**, matching
`Math.modBy`, `Math.remainderBy` and `Bitwise.shiftLeftBy`:

```gren
a |> BigInt.subBy one          -- a - 1
a |> BigInt.quotRemBy two      -- a / 2
a |> BigInt.shiftLeftBy 8      -- a << 8
```

`compare` is the exception, and for the same reason: it stands in for
`Basics.compare`, so it takes its arguments the way that one does.

## How it works

Sign and magnitude: a `Bool` and an array of 24-bit limbs, least significant
first. Twenty-four bits because every power-of-two base anyone formats in
divides it evenly — six hex digits to a limb, eight octal, twenty-four binary —
so those conversions are slicing rather than arithmetic. And because a limb
times a limb plus a carry stays under 2^48, which a double still holds exactly.

Multiplication is long multiplication a row at a time. Division is Knuth's
algorithm D, written as a fold rather than as mutation of a scratch buffer,
with both operands normalised first so the trial quotient is never more than
two too high.

## Tests

```sh
cd tests && ./run.sh
```

Four kinds, in the order they catch things:

- **Differential** runs every operation twice — once through `BigInt`, once
  through Gren's own `Int` — over every pair in −24…24 and over pairs
  straddling the 2^24 limb boundary. Anything an `Int` can check, it checks.
- **BigNumbers** picks up past 2^53, where the point of the package is, against
  values from an independent implementation.
- **Bits** covers the two's-complement reading of negatives and the width
  views, against what Python gives for the same expressions.
- **Strings** covers parsing and formatting in every base from 2 to 36,
  including the refusals.
