pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

pub fn maybe_div(a: i32, b: i32) -> Option<i32> {
    if b == 0 {
        None
    } else {
        Some(a / b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_works() {
        assert_eq!(add(2, 2), 4);
    }

    #[test]
    fn maybe_divides() {
        assert_eq!(maybe_div(10, 2), Some(5));
        assert_eq!(maybe_div(1, 0), None);
    }
}
