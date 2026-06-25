use serde_json::Value;
fn main() {
    let v: Value = serde_json::from_str(r#"{"a":[1,2,3],"b":{"c":42},"s":"hello"}"#).unwrap();
    let n = v["b"]["c"].as_i64().unwrap();
    let re = regex::Regex::new(r"(\d+)-(\d+)").unwrap();
    let caps = re.captures("123-456").unwrap();
    let sum: i64 = caps[1].parse::<i64>().unwrap() + caps[2].parse::<i64>().unwrap();
    std::process::exit(if n == 42 && sum == 579 { 42 } else { 1 });
}
