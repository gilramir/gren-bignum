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

The operands are fine at any size; it is the **quotient** that has to fit.
`281474976710656 // 16777216` is correct, because the answer is only 2^24. A
division is silently wrong exactly when its result lands outside signed 32-bit
range — including `bigNumber // 1`.

Filed as [gren-lang/compiler#383](https://github.com/gren-lang/compiler/issues/383):
the compiler inlines `//` as `(a / b) | 0` while core's kernel uses
`Math.trunc`, so the same expression gives two answers depending on whether it
was inlined.

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
| division | `quotRemBy` truncating, `divModBy` flooring, and either half of either alone |
| comparison | `compare` `max` `min` `isZero` `isNegative` `isEven` `isOdd` |
| bits | `and` `or` `xor` `complement` `shiftLeftBy` `shiftRightBy` `bitLength` `popCount` |
| widths | `maskTo` `toSigned` `fitsSigned` `fitsUnsigned` |
| text | `fromString` `toString`, and the same with a base from 2 to 36 |
| numbers | `fromInt` `toInt` `fromFloat` `toFloat` |

**Both divisions, because a programmer gets asked both.** `quotRemBy` truncates
toward zero and its remainder takes the dividend's sign, which is C. `divModBy`
floors and its modulus takes the divisor's sign, which is Python. `-7 / 2` is
`-3` remainder `-1` in one and `-4` modulus `1` in the other. Neither is more
correct; which you want depends on which language you are checking.

Each also comes as its two halves — `quotBy` and `remainderBy`, `divBy` and
`modBy` — because wanting only the quotient is the common case, and paying for
it with a `Maybe.map .quotient` at every call site reads like an apology:

```gren
a |> BigInt.divBy b        -- Maybe BigInt
a |> BigInt.quotRemBy b    -- Maybe { quotient, remainder }, when you want both
```

The pair is still the one to use when you want both, since it does the single
division that produces them.

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

**Floats go in exactly and come out rounded, and only one of those is
surprising.** `fromFloat` truncates toward zero — `-3.7` is `-3`, not `-4` —
and `NaN` and the infinities are `Nothing`. What it is not is approximate:

```gren
BigInt.fromFloat 1.0e30 |> Maybe.map BigInt.toString
--> Just "1000000000000000019884624838656"
```

Those digits are not noise. That *is* `1e30` — past a certain exponent a
double is an integer, just not usually the one you typed, and this is the
function that shows you which one you actually have.

`toFloat` is the lossy direction, because a `Float` is the thing with the
fixed significand:

```gren
toFloat (2^64 + 1) == toFloat (2^64)   -- True; the 1 is gone
toString (2^64 + 1)                    -- "18446744073709551617"; still there
```

So a `BigInt` survives a round trip through a `String` and does not survive
one through a `Float` above 2^53. If you are storing these anywhere, store
the string. `toInt` is the one that refuses rather than rounds.

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
Algorithm D, written as a fold rather than as mutation of a scratch buffer,
with both operands normalised first so the trial quotient is never more than
two too high.

## Where the technique comes from

None of the arithmetic here is original, and the parts of it that look clever
are sixty years old. Since this is the sort of thing that gets mistaken for
invention, here is who it actually belongs to.

**Limbs smaller than the machine's exact range** is the standard way to build
multi-precision arithmetic on a numeric type that cannot detect its own
overflow. Knuth sets out the classical algorithms for an arbitrary radix *b* in
*The Art of Computer Programming*, Vol. 2, §4.3.1 — Algorithm A (addition),
S (subtraction), M (multiplication) and D (division) — and every operation in
this package is one of those four. The division is Algorithm D as given there,
including the normalisation step and the result that a trial quotient formed
from the leading digits is then never more than two too large. The `correct`
loop in the source exists because of that bound, and would be unbounded
without it.

**Choosing the radix below the word size** is what every implementation on a
platform with no double-width integer type does. CPython stores 30-bit digits
in a 32-bit type so that a product fits the `twodigits` type it multiplies
into; [bn.js][bnjs], working with exactly the doubles Gren has, uses 26-bit
limbs, because 26 + 26 = 52 fits inside a double's 53-bit significand. The
reasoning behind 24 here is theirs, not ours.

**What is local to this package is the number itself, and it is a trade rather
than an idea.** 26 bits would give more room per limb. 24 gives two of those
bits up to buy a different property: it is divisible by 1, 2, 3 and 4, so
binary, octal and hexadecimal all land on limb boundaries, and formatting in
them is slicing instead of repeated division. For a package whose reason to
exist is looking at values in hex, that is the right way round — but it is a
choice among standard ones, not a new one.

### References

- Donald E. Knuth, *The Art of Computer Programming*, Vol. 2: *Seminumerical
  Algorithms*, §4.3.1 "The Classical Algorithms".
- CPython, [`Include/cpython/longintrepr.h`][cpython] — 30-bit digits, and the
  constraints on `PyLong_SHIFT` that decide them.
- [bn.js][bnjs] — 26-bit limbs, the same trade on the same doubles.

[cpython]: https://github.com/python/cpython/blob/main/Include/cpython/longintrepr.h
[bnjs]: https://github.com/indutny/bn.js/

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
