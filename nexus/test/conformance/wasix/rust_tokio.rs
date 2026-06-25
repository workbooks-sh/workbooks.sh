use std::time::Duration;
fn main() {
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap();
    let n: i64 = rt.block_on(async {
        let mut sum = 0i64;
        for i in 1..=1000 { tokio::task::yield_now().await; sum += i; }
        tokio::time::sleep(Duration::from_millis(1)).await;
        sum
    });
    std::process::exit(if n == 500500 { 42 } else { 1 });
}
