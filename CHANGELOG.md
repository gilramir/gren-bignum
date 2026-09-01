# gren-bignum 1.0.0

Renamed from `gilramir/gren-bigint`, because there is more than one kind of
number in it now. A new name is a new package as far as the registry is
concerned, so the version starts over; `gilramir/gren-bigint` 1.0.0 stays where
it is.

- **New: `BigDecimal`** — exact decimal numbers, as an unscaled `BigInt` over a
  power of ten. Arithmetic that never rounds, division that is either exact or
  `Nothing`, division to a number of places that always answers, and the seven
  IEEE 754 roundings. Trailing zeroes are stripped, so `1.50 == 1.5` and `==`
  is numeric equality.
- `BigInt` is unchanged, and its API is the whole of what `BigDecimal` is
  built on.

# gren-bigint 1.0.0

First release.
