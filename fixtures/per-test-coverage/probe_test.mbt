///|
test "left-short-circuits" {
  let rhs_calls : Ref[Int32] = { val: 0, }
  assert_false(@turtles_coverage_fixture.probe(false, 1, rhs_calls))
  assert_eq(rhs_calls.val, 0)
  assert_eq(@turtles_coverage_fixture.left(), 1)
}

///|
test "right-short-circuits" {
  let rhs_calls : Ref[Int32] = { val: 0, }
  assert_false(@turtles_coverage_fixture.probe(false, 20, rhs_calls))
  assert_eq(rhs_calls.val, 0)
  assert_eq(@turtles_coverage_fixture.right(), 2)
}

///|
test "property-disabled-probe" {
  @quickcheck.check(
    (x : Int32) => {
      let rhs_calls : Ref[Int32] = { val: 0, }
      let result = @turtles_coverage_fixture.probe(false, x, rhs_calls)
      !result && rhs_calls.val == 0
    },
    count=8,
    seed=42,
  )
}
