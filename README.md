# gren-bignum

Arbitrary-precision integers and exact decimals for [Gren](https://gren-lang.org).

```gren
import BigInt
import BigDecimal

BigInt.fromString "0xFFFFFFFFFFFFFFFF"
    |> Maybe.map BigInt.toString
    --> Just "18446744073709551615"

BigDecimal.fromString "0.1"
    |> Maybe.map (\d -> BigDecimal.add d d |> BigDecimal.add d)
    |> Maybe.map BigDecimal.toString
    --> Just "0.3"
```

**TL;DR.** A Gren `Int` is a double, so it is exact up to 2^53 and wrong
above that, and Gren's `//` operator is wrong far sooner than that. `BigInt`
is an integer with no upper limit, plus the `uint64`- and `int32`-shaped views
you need when you are checking what a real machine did. `BigDecimal` is a
`BigInt` with a decimal point: it adds and multiplies without rounding, and
rounds only when you tell it to and say how. The implementation is the
classical algorithms on 24-bit limbs, and section 6 explains why 24.

## Table of contents

- [1. Why a Gren program needs this](#1-why-a-gren-program-needs-this)
- [2. BigInt](#2-bigint)
- [3. Widths](#3-widths)
- [4. Argument order](#4-argument-order)
- [5. BigDecimal](#5-bigdecimal)
- [6. How it is built](#6-how-it-is-built)
- [7. Where the techniques come from](#7-where-the-techniques-come-from)
- [8. Tests](#8-tests)

---

## 1. Why a Gren program needs this

Gren has one numeric representation: the JavaScript double. An `Int` is a
double that happens to hold a whole number, and it stays exact up to 2^53.
Past that, it rounds. That's fine until you are working out what a `uint64`
did, and then it is the whole problem: `2^64 - 1` comes back as
`18446744073709552000`, and nothing tells you that the last four digits are
wrong.

Division goes wrong much earlier, and that is the bug that started this
package. Gren's `//` compiles to `(a / b) | 0`, and the `| 0` truncates the
**result** to 32 bits:

```gren
281474976710656 // 2  --> 0            -- 2^48 / 2
2147483648 // 1       --> -2147483648  -- 2^31
```

The operands can be any size. It is the quotient that has to fit in a signed
32-bit integer. `281474976710656 // 16777216` is correct, because the answer
is only 2^24, while `bigNumber // 1` is wrong for any `bigNumber` past 2^31.
We reported this as
[gren-lang/compiler#383](https://github.com/gren-lang/compiler/issues/383):
the compiler inlines `//` as `(a / b) | 0`, while core's own kernel code uses
`Math.trunc`, so the same expression gives two different answers depending on
whether it was inlined.

---

## 2. BigInt

| | |
|---|---|
| arithmetic | `add` `subBy` `mul` `negate` `abs` `powBy` |
| division | `quotRemBy` truncating, `divModBy` flooring, and either half of either alone |
| comparison | `compare` `max` `min` `isZero` `isNegative` `isEven` `isOdd` |
| bits | `and` `or` `xor` `complement` `shiftLeftBy` `shiftRightBy` `bitLength` `popCount` |
| widths | `maskTo` `toSigned` `fitsSigned` `fitsUnsigned` |
| text | `fromString` `toString`, the same with a base from 2 to 36, and the `Within` forms of both readers for text you did not write |
| numbers | `fromInt` `toInt` `fromFloat` `toFloat` |

### Two divisions

There are two divisions because different languages define it differently,
and you are usually checking one of them. `quotRemBy` truncates toward zero
and its remainder takes the sign of the dividend; that is C. `divModBy`
floors and its modulus takes the sign of the divisor; that is Python. So
`-7 / 2` is `-3` remainder `-1` in the first and `-4` modulus `1` in the
second. Neither is more correct than the other.

Each division also comes as its two halves, `quotBy` and `remainderBy`,
`divBy` and `modBy`, because most of the time you only want the quotient:

```gren
a |> BigInt.divBy b        -- Maybe BigInt
a |> BigInt.quotRemBy b    -- Maybe { quotient, remainder }
```

When you want both, use the pair. It does one division and returns both
parts of it.

### Bits

The bitwise operations treat a value as two's complement of unbounded width.
`complement (fromInt 5)` is `-6`, and `and (fromInt -6) (fromInt 3)` is `2`.
These are the same answers Python gives, and they are the only sensible
answers when nobody has said how wide the number is. `shiftRightBy` is an
arithmetic shift, so it floors: `-1` shifted right by any amount is still
`-1`.

### Strings

A string carries a sign, not a two's complement. `toStringWithBase 16
(fromInt -255)` is `"-ff"`. If you want the bit pattern a machine would show
for a 64-bit value, apply `maskTo 64` first; that is what it is for.

`fromString` accepts `0x`, `0b` and `0o` prefixes in either case, an optional
sign, and underscores between digits, so `0xdead_beef` parses. Anything it
does not understand returns `Nothing`, never zero.

`fromStringWithin` is `fromString` for text you did not write. Parsing is
quadratic in the length of the text, so a million-digit string is a real
cost, and the plain function will pay it. This one takes a limit on the
number of digits, refuses anything longer before doing any arithmetic, and
returns a `Result` so the caller can tell a malformed string from a long one:

```gren
BigInt.fromStringWithin 20 "123456789012345678901"
--> Err (BigInt.TooLong { digits = 21, limit = 20 })
```

`fromStringWithBaseWithin` is the same for `fromStringWithBase`, with the
digits counted in that base.

### Floats

`fromFloat` truncates toward zero, so `-3.7` becomes `-3`, and `NaN` and the
infinities return `Nothing`. What it does not do is approximate. It gives you
the exact integer the double holds:

```gren
BigInt.fromFloat 1.0e30 |> Maybe.map BigInt.toString
--> Just "1000000000000000019884624838656"
```

Those trailing digits are not noise. Above a certain exponent every double is
an integer, just not usually the one that was typed, and this is the function
that shows you which integer you actually have.

`toFloat` is the direction that loses information, because a `Float` has a
fixed-size significand and a `BigInt` does not:

```gren
toFloat (2^64 + 1) == toFloat (2^64)   -- True; the 1 is gone
toString (2^64 + 1)                    -- "18446744073709551617"; still there
```

A `BigInt` survives a round trip through a `String` and, above 2^53, does not
survive one through a `Float`. If you need to store one, store the string.
`toInt` returns `Nothing` rather than round.

---

## 3. Widths

A `BigInt` has no width. Instead, it has a way to ask for one. The width is a
question you put to a value, not a property the value carries around and can
silently violate.

```gren
x |> BigInt.maskTo 64        -- as a uint64
x |> BigInt.toSigned 64      -- as an int64
x |> BigInt.fitsSigned 64    -- would it have overflowed?
```

`maskTo` wraps the way a register does: `maskTo 64 (fromInt -1)` is
`18446744073709551615`, and `toSigned 64` of that is `-1` again.

---

## 4. Argument order

Wherever the order of the operands matters, the subject comes **last**. This
matches `Math.modBy`, `Math.remainderBy` and `Bitwise.shiftLeftBy` in core,
and it makes pipelines read naturally:

```gren
a |> BigInt.subBy one                      -- a - 1
a |> BigInt.quotRemBy (BigInt.fromInt 2)   -- a / 2
a |> BigInt.shiftLeftBy 8                  -- a << 8
```

`compare` is the exception. It stands in for `Basics.compare`, so it takes
its arguments in the same order that one does.

---

## 5. BigDecimal

A `Float` cannot hold `0.1`. What it holds is
`0.1000000000000000055511151231257827`, which is close enough until you add
three of them and get `0.30000000000000004`. The addition is not at fault;
base two has no exact `0.1` to add. `BigDecimal` works in base ten, so it
does.

A value is an unscaled `BigInt` and a power of ten: `unscaled * 10^-scale`.
There is no fixed precision anywhere, so `add`, `subBy` and `mul` never round.
They widen. The only operation that can fail to terminate is division, and
division and `roundTo` are the only operations that take a rounding mode.

| | |
|---|---|
| arithmetic | `add` `subBy` `mul` `negate` `abs` `powBy` |
| division | `divBy` exact or `Nothing`, `divByTo` to a number of places |
| rounding | `roundTo`, and the seven `Rounding` modes |
| comparison | `compare` `isZero` `isNegative` `isInteger` `max` `min` |
| text | `fromString` `toString` `toStringWithPlaces`, and `fromStringWithin` for text you did not write |
| numbers | `fromInt` `toInt` `fromBigInt` `toBigInt` `fromFloat` `toFloat` |
| representation | `scale` `unscaled` `movePointBy` |

### One value, one representation

`1.50` and `1.5` are the same number, and in this module they are also the
same value. Every `BigDecimal` goes through a constructor that strips
trailing zeroes.

```gren
BigDecimal.fromString "1.50" == BigDecimal.fromString "1.5"   -- True
```

This is the opposite of `java.math.BigDecimal`, where the two are equal by
`compareTo` but distinct by `equals`. We differ because Gren's `==` is
structural and cannot be overridden. A type whose `==` disagrees with its
`compare` is a trap in the language's most-used operator, and no amount of
documentation removes it.

The cost is that the scale no longer records significance. A `BigDecimal`
does not remember that a price was quoted to the cent. That is a formatting
question, and you ask it at the edge:

```gren
BigDecimal.toStringWithPlaces 2 price   --> "1.50"
```

### Two divisions, for a different reason

`BigInt` has two divisions because two languages disagree. `BigDecimal` has
two because a decimal division either terminates or it does not, and only the
caller knows which outcome is acceptable.

```gren
BigDecimal.one |> BigDecimal.divBy (BigDecimal.fromInt 8)   -- Just 0.125
BigDecimal.one |> BigDecimal.divBy (BigDecimal.fromInt 3)   -- Nothing
```

`divBy` returns the exact quotient or `Nothing`. A quotient terminates in
base ten only when the reduced divisor is made of twos and fives, and if your
program expected `1/3` to come out as a number, the `Nothing` is telling you
something. `divByTo` always answers, because you have told it how many places
to keep and what to do with the last one:

```gren
BigDecimal.one |> BigDecimal.divByTo 5 BigDecimal.HalfEven (BigDecimal.fromInt 3)
--> Just 0.33333
```

### The seven roundings

`Up` and `Down` ignore how close the value was to the boundary. `Ceiling` and
`Floor` depend on the sign of the number. `HalfUp`, `HalfDown` and `HalfEven`
all go to the nearer value and differ only on an exact tie. These are the
rounding modes of Python's `decimal` module under Java's names for them, and
the test suite checks all seven against Python.

Where this module has to round without being asked, inside
`toStringWithPlaces`, it uses `HalfEven`. Splitting ties in both directions
is what keeps a long column of rounded numbers from drifting upward.

### Reading text you did not write

`fromString` does what it is told, and the exponent makes that a hazard:
`1e-9999999999` is thirteen characters and needs ten billion digits to hold.
`fromStringWithin` takes a limit on the number of digits the value would take
to write out, works that number out from the text alone, and returns
`Err (TooLong { digits, limit })` before building anything:

```gren
BigDecimal.fromStringWithin 10 "1e-9999999999"
--> Err (BigDecimal.TooLong { digits = 10000000000, limit = 10 })
```

### The example that makes the case

```gren
BigDecimal.fromString "2.675" |> Maybe.map (BigDecimal.roundTo 2 BigDecimal.HalfUp)
--> Just 2.68

BigDecimal.fromFloat 2.675 |> Maybe.map (BigDecimal.roundTo 2 BigDecimal.HalfUp)
--> Just 2.67
```

Both answers are right. The nearest double to `2.675` is
`2.67499999999999982...`, which is below the tie, so it rounds down. Every
language that rounds a `Float` gives `2.67` here and gets blamed for it.
`fromString` gives you the number that was written and `fromFloat` gives you
the number the machine has, and the fact that those differ is the reason to
have a decimal type at all.

---

## 6. How it is built

A `BigInt` is a sign and a magnitude: a `Bool` and an array of 24-bit limbs,
least significant first. A 64-bit value takes three limbs, and the limbs do
not line up with the 64 bits, because the value has no width.

```
0xDEADBEEFCAFEBABE  =  16045690984503098046

     limb 2     limb 1     limb 0
    0x00DEAD   0xBEEFCA   0xFEBABE
      57005    12513226   16693950

stored as [ 0xFEBABE, 0xBEEFCA, 0x00DEAD ]   -- least significant first
```

Little-endian is the order the arithmetic wants. Limb 0 is where addition
starts and where the first carry comes from, so growing a number is a
`pushLast` and never a shift of everything already there.

### Why 24 bits

A limb width has a ceiling and a floor, and there is less room between them
than you might expect.

The ceiling comes from the double. Three places in the arithmetic need a
value two limbs wide to be exact: the partial product in `mulByLimb`, the
running `remainder * 2^24 + limb` when dividing by a single limb, and
Algorithm D's trial quotient, which reads the top two limbs of the remainder
as one number. Each of those is `2b` bits, so `2b <= 53`, and a limb can be
at most 26 bits. CPython uses 30, but it can, because it has a `uint64` to
multiply into. Gren has no such type. [bn.js][bnjs], which works with the
same doubles Gren has, sits at the ceiling with 26.

The floor comes from base ten. A base that does not divide the limb width is
printed by repeatedly dividing the number by the largest power of that base
that fits in one limb, so what a limb width buys decimal conversion is the
number of digits in that power:

| limb bits | largest power of ten in a limb | two limbs still exact |
|---|---|---|
| 23 | 10^6, six digits | yes |
| **24** | **10^7, seven digits** | **yes** |
| 25 | 10^7, seven digits | yes |
| 26 | 10^7, seven digits | yes |
| 27 | 10^8, eight digits | **no** |

Seven digits per pass is the most a double allows. Eight would need `10^8` to
fit in a limb, which takes 27 bits, and would need `10^8 * 2^b` to stay exact
so we can divide by it, which allows at most 26. Those two requirements never
meet. So 24 is the *smallest* limb that gets the best decimal conversion
available on this platform, and 25 and 26 spend their extra bits without
buying decimal a single digit.

That leaves 24, 25 and 26 as equals for the base most people read, and the
tie is settled by divisibility. Twenty-four is divisible by 1, 2, 3 and 4:

```
2^24  =  16^6  =  8^8  =  4^12
```

One limb is exactly six hex digits, exactly eight octal digits, exactly
twenty-four binary digits. In any of those bases the answer *is* the limbs,
written most significant first and padded to width, and that is what
`toStringWithBase` does for them:

```
    00dead  beefca  febabe        -- each limb as six hex digits
->  deadbeefcafebabe              -- leading zeroes off the top limb

    00157255 57567712 77535276    -- each limb as eight octal digits
->  1572555756771277535276
```

No carries, no division, and nothing that depends on how big the number is: a
digit of a limb is already a digit of the answer, in the right place. The one
subtlety is that the top limb is written at its natural width and every limb
below it is padded to the full six. An interior zero limb is six zero digits
of the number, and dropping them would print `2^48 + 1` as `11`.

Decimal still has to be divided down, since 10^7 < 2^24 < 10^8 means a limb
is never a whole number of decimal digits and the carries cross limb
boundaries. But that is the platform's limit, not a price paid for the hex,
because no limb width a double allows does any better.

What the two bits below the ceiling do cost is general arithmetic. 26-bit
limbs would mean about 8% fewer limbs, so roughly 15% off a multiplication
and less off everything linear. Against that, formatting in the four sliced
bases is the twelvefold difference measured below. And at the sizes this
package is for, the 15% is theoretical: a 64-bit value is three limbs either
way, and a 256-bit value is eleven limbs against ten.

### What the other thirty-one bases have to do

`toStringWithBase` slices the limbs for bases 2, 4, 8 and 16, and only those.
Every other base has to divide: find the largest power of the base that fits
in a limb, divide the number by it repeatedly, and pad each remainder.

| base | route | digits at a time |
|---|---|---|
| 2 | sliced | 24 |
| 4 | sliced | 12 |
| 8 | sliced | 8 |
| 16 | sliced | 6 |
| 10 | divided by 10^7 | 7 |
| 32 | divided by 32^4 | 4 |
| 36 | divided by 36^4 | 4 |

Base 32 looks like it should qualify and does not. It is a power of two, but
a digit is five bits and 24 is not divisible by five, so its digits straddle
limb boundaries like any other base's.

The difference is not small. Dividing the number down is quadratic, because
each chunk of digits walks every limb, and slicing is linear. Formatting an
8192-bit number in hex three hundred times:

```
divided:  477 ms
sliced:    38 ms
```

Both routes give the same string. The round-trip test writes and re-reads
each of the eleven sample values in all thirty-five bases, so the two routes
are held to the same answers.

### The arithmetic

Multiplication is long multiplication, one row at a time. Division is Knuth's
Algorithm D, written as a fold rather than as mutation of a scratch buffer,
with both operands normalised first so the trial quotient is never more than
two too high.

### The decimals on top

`BigDecimal` adds no arithmetic of its own. It is a `BigInt` and an `Int`
scale, and every operation is a scale adjustment followed by the integer
operation: `add` widens both operands to the finer scale, `mul` adds the
scales, and each rounding is one truncating division plus a conditional step
away from zero. The one piece with any reasoning in it is the test for
whether an exact division terminates, and it turns out not to need a greatest
common divisor. Write the divisor as `2^a * 5^b * m`; then `n / d`
terminates exactly when `d` divides `n * 10^k` for `k = max a b`. Asking for
that one division both answers the question and produces the digits.

---

## 7. Where the techniques come from

None of the arithmetic here is original, and the parts that look clever are
sixty years old. This section says who it belongs to.

**Limbs smaller than the machine's exact range** is the standard way to build
multi-precision arithmetic on a numeric type that cannot detect its own
overflow. Knuth gives the classical algorithms for an arbitrary radix *b* in
*The Art of Computer Programming*, Vol. 2, §4.3.1: Algorithm A (addition), S
(subtraction), M (multiplication) and D (division). Every operation in this
package is one of those four. The division is Algorithm D as given there,
including the normalisation step and the result that a trial quotient formed
from the leading digits is never more than two too large. The `correct` loop
in the source exists because of that bound, and would be unbounded without
it.

**Choosing the radix below the word size** is what every implementation does
on a platform with no double-width integer type. CPython stores 30-bit digits
in a 32-bit type so that a product fits the `twodigits` type it multiplies
into. [bn.js][bnjs], on the same doubles Gren has, uses 26-bit limbs, because
26 + 26 = 52 fits inside a double's 53-bit significand. The reasoning behind
24 here is theirs.

**What is local to this package is the particular number**, and it is a pick
within a range rather than an idea. A double allows at most 26 bits, and base
ten gets the best conversion available (seven digits a pass) from 24 up, so
as far as decimal is concerned 24, 25 and 26 are equals. Of those, 24 is the
one divisible by 1, 2, 3 and 4, so binary, octal and hexadecimal land on limb
boundaries and formatting in them is slicing rather than repeated division.
The two bits it gives up cost about 15% of a multiplication and nothing of a
decimal conversion. Even so, it is a choice among standard options, not a new
one.

**The decimal representation is not ours either.** An unscaled integer and a
decimal exponent is what `java.math.BigDecimal` is, what Python's `decimal`
module is, and what IEEE 754-2008 standardised as a decimal format. The seven
roundings are that standard's, under Java's names. The one choice made here
rather than inherited is stripping trailing zeroes so that `==` is numeric
equality, and that is a concession to Gren's structural equality rather than
an improvement. Java keeps the scale and can afford to, because it gets to
write its own `equals`.

### References

- Donald E. Knuth, *The Art of Computer Programming*, Vol. 2: *Seminumerical
  Algorithms*, §4.3.1 "The Classical Algorithms".
- CPython, [`Include/cpython/longintrepr.h`][cpython]: 30-bit digits, and the
  constraints on `PyLong_SHIFT` that decide them.
- [bn.js][bnjs]: 26-bit limbs, the same trade on the same doubles.
- IEEE 754-2008, §3.5: decimal formats as a significand and an exponent, and
  the rounding-direction attributes.
- Python's [`decimal`][pydecimal] module, which the `Decimals` suite checks
  against.

[pydecimal]: https://docs.python.org/3/library/decimal.html
[cpython]: https://github.com/python/cpython/blob/main/Include/cpython/longintrepr.h
[bnjs]: https://github.com/indutny/bn.js/

---

## 8. Tests

```sh
cd tests && ./run.sh
```

Five suites, in the order they catch things:

- **Differential** runs every operation twice, once through `BigInt` and once
  through Gren's own `Int`, over every pair in −24…24 and over pairs
  straddling the 2^24 limb boundary. Anything an `Int` can check, it checks.
- **BigNumbers** picks up past 2^53, where the point of the package is,
  against values from an independent implementation.
- **Bits** covers the two's-complement reading of negatives and the width
  views, against what Python gives for the same expressions.
- **Strings** covers parsing and formatting in every base from 2 to 36,
  including the inputs that must be refused.
- **Decimals** covers `BigDecimal`: the normal form that makes `==` numeric
  equality, arithmetic a `Float` gets visibly wrong, and all seven roundings
  on the ties where they disagree, against Python's `decimal`.
