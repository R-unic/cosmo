![build](https://github.com/R-unic/cosmo/actions/workflows/crystal.yml/badge.svg)
# Cosmo

Cosmo is a statically-typed programming language written in pure Crystal.<br>
We have an [extension for VS code](https://marketplace.visualstudio.com/items?itemName=cosmo.vscode-cosmo) ([source](https://github.com/R-unic/vscode-cosmo)), however it currently only features syntax highlighting.

## Things I Gotta Do

- Fix funky function return type parsing
- Literal wrapper classes (vector, table)
- Interfaces
- Classes
  * single inheritance
  * mixins
  * visibilities
  * methods
  * $ (this)
- Better type system
  * unions/intersections

## Gotchas

### Table type definitions
Type definitions for tables can be amibigous.<br>
I plan to fix this in the future. For example:
```go
string->string->string my_table
```
Currently, this type resolves to a table with string keys, and string->string values.<br>
Using a type alias here is broken currently, but is clearly what makes sense to use.<br>
In the future (but not right now), this code should be valid:
```crystal
type MyTable = string->string
MyTable->string weird_table = {
  [{"some" -> "thing"}] -> "hello world"
}
puts(weird_table[{"some" -> "thing"}]) ## hello world
```

## Installation

1. Install [Crystal](https://crystal-lang.org/install/).
2. Run `sudo make install`.
3. Assert everything is working by running `cosmo -h`

## Contributing

1. Fork it (<https://github.com/R-unic/cosmo/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Test your code (`make test`)
5. Push to the branch (`make publish`)
6. Create a new Pull Request

## Contributors

- [R-unic](https://github.com/R-unic) - creator and maintainer
