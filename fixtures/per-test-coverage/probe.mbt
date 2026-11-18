///|
fn below(x : Int32, rhs_calls : Ref[Int32]) -> Bool {
  rhs_calls.val += 1
  x < 10
}

///|
pub fn probe(enabled : Bool, x : Int32, rhs_calls : Ref[Int32]) -> Bool {
  enabled && below(x, rhs_calls)
}

///|
pub fn left() -> Int32 {
  1
}

///|
pub fn right() -> Int32 {
  2
}
