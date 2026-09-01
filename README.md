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

**TL;DR.** A Gren `Int` is a stored in a JavaScript double floating-point,
so it is exactup to 2^53 and wrong above that, and Gren's `//`
operator is wrong far sooner than that. `BigInt` is an integer with no
upper limit, plus the `uint64`- and `int32`-shaped views if you need
them. `BigDecimal` is a `BigInt` with a decimal point: it adds and
multiplies without rounding, and rounds only when you tell it to and
say how. The implementation is the classical algorithms on 24-bit limbs,
and section 6 explains why 24.

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

Side by side, starting where the two agree and then putting a negative on
each side of the slash:

```gren
-- 7 / 2: both positive, and the two divisions agree

BigInt.fromInt 7 |> BigInt.quotRemBy (BigInt.fromInt 2)
--> Just { quotient = 3, remainder = 1 }

BigInt.fromInt 7 |> BigInt.divModBy (BigInt.fromInt 2)
--> Just { quotient = 3, modulus = 1 }

-- -7 / 2: a negative dividend

BigInt.fromInt -7 |> BigInt.quotRemBy (BigInt.fromInt 2)
--> Just { quotient = -3, remainder = -1 }

BigInt.fromInt -7 |> BigInt.divModBy (BigInt.fromInt 2)
--> Just { quotient = -4, modulus = 1 }

-- 7 / -2: a negative divisor

BigInt.fromInt 7 |> BigInt.quotRemBy (BigInt.fromInt -2)
--> Just { quotient = -3, remainder = 1 }

BigInt.fromInt 7 |> BigInt.divModBy (BigInt.fromInt -2)
--> Just { quotient = -4, modulus = -1 }
```

Both satisfy `divisor * quotient + rest == dividend`. They differ in which
way the quotient is pushed when it does not come out whole, and that decides
the sign of what is left over.

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
A negative number is not a fixed field of bits with the top one set; it is a
sign bit that repeats forever to the left, written `...` here:

```
        ...00000101     5
    ~   ...11111010    -6      complement (fromInt 5)

        ...11111010    -6
    &   ...00000011     3
    =   ...00000010     2      and (fromInt -6) (fromInt 3)

        ...11111010    -6
    |   ...00000011     3
    =   ...11111011    -5      or (fromInt -6) (fromInt 3)

        ...11111111    -1
    >>3 ...11111111    -1      shiftRightBy 3 (fromInt -1)
```

These are the same answers Python gives, and they are the only sensible
answers when nobody has said how wide the number is. `shiftRightBy` is an
arithmetic shift, so it floors, and the last line above is why: the ones
never run out, so `-1` shifted right by any amount is still `-1`.

The bits above are the arithmetic, not the text. `toStringWithBase 2` writes
a sign and a magnitude, so it prints `-6` as `-110`; the next section says
how to get the other picture.

### Strings

A string carries a sign, not a two's complement. `toStringWithBase 16
(fromInt -255)` is `"-ff"`. If you want the bit pattern a machine would show
for a 64-bit value, apply `maskTo 64` first; that is what it is for.

`fromString` accepts `0x`, `0b` and `0o` prefixes in either case, an optional
sign, and underscores between digits, so `0xdead_beef` parses. Anything it
does not understand returns `Nothing`, never zero.

`fromStringWithin` is `fromString` for text you did not write. Parsing is
quadratic in the length of the text — [section 6 says
why](#reading-is-quadratic-in-every-base) — so a million-digit string is a
real cost, and the plain function will pay it. This one takes a limit on the
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
division and `roundTo` are the only operations that round a value.
`toStringWithPlacesUsing` takes a rounding mode too, but only to write a value
down.

| | |
|---|---|
| arithmetic | `add` `sum` `subBy` `mul` `negate` `abs` `powBy` |
| division | `divBy` exact or `Nothing`, `divByTo` to a number of places |
| splitting | `allocate` into equal parts, `allocateBy` in proportion, both adding back up |
| rounding | `roundTo`, and the seven `Rounding` modes |
| comparison | `compare` `isZero` `isNegative` `isInteger` `max` `min` |
| text | `fromString` `toString` `toStringWithPlaces` `toStringWithPlacesUsing`, and `fromStringWithin` for text you did not write |
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
does not remember that a price was quoted to the cent. Two decimal places is
a formatting decision, so make it where the value becomes text:

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

### Splitting a total

Dividing answers "what is one share" and answers it for one share at a time,
which is why the shares stop adding up. Ten pounds in three is `3.33` to the
cent however it is rounded, and three of those is `9.99`. The missing penny is
not a rounding to be tuned away -- at two places there is no answer that works
-- so somebody has to be given it.

```gren
BigDecimal.fromString "10.00" |> Maybe.andThen (BigDecimal.allocate 2 3)
--> Just [ 3.34, 3.33, 3.33 ]
```

The first argument is where the smallest unit sits: `2` for a currency with
cents, `0` for one without. The parts differ by one unit at most, the earliest
take the extra, and they add up to what you passed in.

`allocateBy` does the same in proportion to a set of weights, which is the one
a shopping cart wants -- an order-level discount has to come off the lines,
and it has to come off them exactly, or the lines stop explaining the total:

```gren
BigDecimal.allocateBy 2 [ line1, line2, line3 ] discount
```

Each part is its exact share rounded toward zero, and the units left over go
to the parts whose discarded fractions were biggest. That is the
largest-remainder method. Weights are relative, so `[ 1, 1, 2 ]` and
`[ 25, 25, 50 ]` split alike.

Both refuse a total that is not a whole number of units at that many places,
rather than rounding it quietly: `allocate 2` will not split `10.005`, because
a third of a cent is not something to hand anybody. Round it first, and own
the rounding.

### The seven roundings

`Up` and `Down` ignore how close the value was to the boundary. `Ceiling` and
`Floor` depend on the sign of the number. `HalfUp`, `HalfDown` and `HalfEven`
all go to the nearer value and differ only on an exact tie. The test suite
checks all seven against Python.

**`Up` and `Down` mean away from zero and toward zero**, not up and down the
number line. That is Java's vocabulary, and it is the one thing about these
names worth saying twice, because `Ceiling` and `Floor` are the ones that go
up and down:

```gren
roundTo 0 Up      (-2.5)   --> -3     -- away from zero
roundTo 0 Down    (-2.5)   --> -2     -- toward zero
roundTo 0 Ceiling (-2.5)   --> -2     -- toward +infinity
roundTo 0 Floor   (-2.5)   --> -3     -- toward -infinity
```

The semantics and the names come from different places, deliberately. The
seven behaviors are Python's `decimal` module's, because that is what the
tests check against. The names are `java.math.RoundingMode`'s, because
Python spells the same seven `ROUND_HALF_EVEN` and the prefix is noise inside
a type already called `Rounding`, while Java's bare words are already
CamelCase and already familiar from Java, C#, SQL and Python alike.

There is a third set of names. JavaScript's `Intl.NumberFormat` says
`expand` and `trunc` where Java says `UP` and `DOWN`, and those are the
clearer words: they say which way the value moves. If you are coming from
either, here is the mapping:

| here | Python `decimal` | JS `Intl` |
|---|---|---|
| `Up` | `ROUND_UP` | `expand` |
| `Down` | `ROUND_DOWN` | `trunc` |
| `Ceiling` | `ROUND_CEILING` | `ceil` |
| `Floor` | `ROUND_FLOOR` | `floor` |
| `HalfUp` | `ROUND_HALF_UP` | `halfExpand` |
| `HalfDown` | `ROUND_HALF_DOWN` | `halfTrunc` |
| `HalfEven` | `ROUND_HALF_EVEN` | `halfEven` |

Python's eighth mode, `ROUND_05UP`, is not here, and neither is Java's
`UNNECESSARY`: `divBy` returning `Nothing` is what that one is for.

Where this module has to round without being asked, inside
`toStringWithPlaces`, it uses `HalfEven`. Splitting ties in both directions is
what keeps a long column of rounded numbers from drifting upward. A price is
not a column, though: shops, invoices and most tax authorities round a half
away from zero, and a total that disagrees with the arithmetic a customer did
by hand is a support ticket whatever IEEE 754 says. `toStringWithPlacesUsing`
is the same function with the mode named -- `HalfEven` for a report, `HalfUp`
for a receipt.

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

---

## 6. How it is built

A `BigInt` is a sign and a magnitude: a `Bool` and an array of 24-bit limbs,
least significant first. Since 24 does not divide 64, a 64-bit value takes
three limbs: two full ones hold 48 bits and the third holds the remaining 16.
The array is as long as the number needs and no longer — nothing in it
records that the value was meant to be 64 bits wide.

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

Two constraints bracket the choice: the double's 53-bit significand puts a
ceiling on the limb width, and decimal conversion puts a floor under it.
Together they leave three widths to choose between.

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

### Reading is quadratic in every base

Writing has a linear route for four bases. Reading has one for none of them.
`fromStringWithBase` scans the text once, and then hands the digits to
Horner's scheme:

```gren
step char total =
    add (mul total radix) (fromInt (Maybe.withDefault 0 (digitValue char)))
```

Multiply the running total by the base, add the next digit, once per digit.
The multiply is by a single limb, so it costs work proportional to the length
of the total *so far* rather than a constant: after `k` decimal digits the
total is about `k / 7.2` limbs long, step `k` walks all of them, and the sum
over `k = 1..n` is on the order of `n^2 / 2`. A million-digit decimal string is
some 10^10 limb operations. That is the cost `fromStringWithin` exists to
refuse, and it can refuse it cheaply because the scan is the linear half:
`scanDigits` drops the separators and validates the characters in one pass
and does no arithmetic at all, so the digit count is known before a single
limb is touched.

The asymmetry with writing is real and not fundamental. Hex is sliced on the
way out but goes through the multiply-and-add on the way in, even though six
hex digits are exactly one limb and could be packed straight into place. Nor
is the constant tight: taking decimal seven digits at a time — accumulate
them in an `Int`, then one multiply by 10^7 — would cut the work by roughly
sevenfold while staying quadratic, and only a divide-and-conquer split would
change the exponent. At the sizes this package is for, neither is worth the
code, and the ceiling `fromStringWithin` puts on the input is the answer to
the case where it would be.

### The arithmetic

Multiplication is long multiplication, one row at a time. Division is Knuth's
Algorithm D, written as a fold rather than as mutation of a scratch buffer,
with both operands normalized first so the trial quotient is never more than
two too high.

### The decimals on top

`BigDecimal` adds no arithmetic of its own. A value is a `BigInt` and a
scale, and every operation adjusts the scales and then hands the work to
`BigInt`.

`add` widens both operands to the finer of the two scales, then adds the
integers. `mul` multiplies the integers and adds the scales:

```
1.5 + 0.25    ->  150 + 25 = 175, scale 2   ->  1.75
1.5 * 0.25    ->   15 * 25 = 375, scale 3   ->  0.375
```

Rounding is one truncating `BigInt` division, followed by a step away from
zero when the discarded remainder and the mode call for one.

That leaves one question with any real reasoning behind it: how `divBy` knows
whether an exact quotient exists. A fraction terminates in base ten only when
the divisor is built from twos and fives, since those are the factors of ten.
So write the divisor as `2^a * 5^b * m` and let `k` be the larger of `a` and
`b`. Multiplying the dividend by `10^k` is then the *only* scaling that could
divide out evenly — a smaller one leaves a two or a five behind, a larger one
gains nothing — so a single division settles the question:

```
1 / 8    8 is 2^3        k = 3    1000 / 8 = 125     ->  0.125
1 / 3    3 is neither    k = 0       1 / 3 leaves 1  ->  Nothing
```

If it comes out even, the quotient is the answer. If it does not, no other
scale would have worked either.

None of that is ours. It is Theorem 135 of Hardy and Wright, which says that
a fraction `p/q` in lowest terms with `q = 2^a * 5^b` terminates after
exactly `max(a, b)` digits — their `μ` is the `k` above. What the code adds
is only that it never reduces the fraction first: the theorem wants lowest
terms, but a factor the dividend shares with the divisor cancels during the
division anyway, so `3 / 6` comes out as `0.5` with no gcd computed. Java's
`BigDecimal` uses the same fact from the other side, throwing rather than
returning when an exact `divide` would not terminate.

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
including the normalization step and the result that a trial quotient formed
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
module is, and what IEEE 754-2008 standardized as a decimal format. Five of
the seven roundings are that standard's rounding-direction attributes wearing
Java's names: `HalfEven` is `roundTiesToEven`, `HalfUp` is `roundTiesToAway`,
and `Ceiling`, `Floor` and `Down` are the three `roundToward` attributes. The
other two are nobody's standard. `Up` and `HalfDown` are additions Java and
Python both make, and a conforming IEEE implementation need not offer either.
The test for whether an exact division terminates is older than any of them:
it is Theorem 135 in Hardy and Wright, from 1938. The one choice made here
rather than inherited is stripping trailing zeroes so that `==` is numeric
equality, and that is a concession to Gren's structural equality rather than
an improvement. Java keeps the scale and can
afford to, because it gets to write its own `equals`.

### References

- Donald E. Knuth, *The Art of Computer Programming*, Vol. 2: *Seminumerical
  Algorithms*, §4.3.1 "The Classical Algorithms".
- CPython, [`Include/cpython/longintrepr.h`][cpython]: 30-bit digits, and the
  constraints on `PyLong_SHIFT` that decide them.
- [bn.js][bnjs]: 26-bit limbs, the same trade on the same doubles.
- IEEE 754-2008, §3.5 and §4.3: decimal formats as a significand and an
  exponent, and the five rounding-direction attributes.
- G. H. Hardy and E. M. Wright, *An Introduction to the Theory of Numbers*,
  §9.2 "Terminating and recurring decimals", Theorem 135: a reduced `p/q`
  with `q = 2^a 5^b` terminates after `max(a, b)` digits. That is the test
  `divBy` performs.
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

Six suites, in the order they catch things:

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
  equality, arithmetic a `Float` gets visibly wrong, all seven roundings on
  the ties where they disagree, and the two allocations, against Python's
  `decimal`.
- **Cart** runs a checkout end to end -- line totals, a discount shared over
  the lines, tax on what is left, the total split three ways -- because the
  order the operations go in is the thing a per-function test cannot check.
