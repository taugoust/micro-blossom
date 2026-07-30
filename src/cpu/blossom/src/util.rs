use konst::{option, primitive::parse_usize, result::unwrap_ctx};
use lazy_static::lazy_static;
use rand::{distributions::Alphanumeric, Rng};
use std::env;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::Mutex;

// by default guarantees working at d=31 circuit-level-noise (30k vertices), but can increase if needed
pub const MAX_NODE_NUM: usize = unwrap_ctx!(parse_usize(option::unwrap_or!(option_env!("MAX_NODE_NUM"), "50000")));

/// a fusion group is a continuous subset of vertices which is recovered simultaneously;
/// it is required that
pub struct FusionGroups {}

/// the runner will first compile the jar package from /src/fpga/microblossom using `sbt`;
/// it allows running main functions in parallel without conflicts due to sbt.
pub struct ScalaMicroBlossomRunner {}

impl ScalaMicroBlossomRunner {
    /// private new function
    fn new() -> Self {
        // A packaged JAR is immutable and was already built by Nix. Preserve
        // the source-tree workflow when no explicit JAR is provided.
        let packaged_jar = env::var_os("MICROBLOSSOM_SCALA_JAR").is_some();
        if !packaged_jar && !env_is_set("MANUALLY_COMPILE_QEC") {
            let mut child = Command::new("sbt")
                .current_dir(Self::source_root())
                .arg("assembly")
                .spawn()
                .unwrap();
            let status = child.wait().expect("failed to wait on child");
            assert!(status.success(), "sbt assembly failed");
        }
        Self {}
    }

    fn source_root() -> PathBuf {
        PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../"))
    }

    fn jar_path() -> PathBuf {
        env::var_os("MICROBLOSSOM_SCALA_JAR")
            .map(PathBuf::from)
            .unwrap_or_else(|| Self::source_root().join("target/scala-2.12/microblossom.jar"))
    }

    fn work_dir() -> PathBuf {
        env::var_os("MICROBLOSSOM_SIM_WORKDIR")
            .map(PathBuf::from)
            .unwrap_or_else(Self::source_root)
    }

    fn java_command(class_name: &str) -> Command {
        let java = env::var_os("JAVA").unwrap_or_else(|| "java".into());
        let heap = env::var("MICROBLOSSOM_JAVA_HEAP").unwrap_or_else(|_| "32G".to_string());
        let mut command = Command::new(java);
        command
            .current_dir(Self::work_dir())
            .arg(format!("-Xmx{heap}"))
            .arg("-cp")
            .arg(Self::jar_path())
            .arg(class_name);
        command
    }

    pub fn run<I, S>(&self, class_name: &str, parameters: I) -> std::io::Result<Child>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        Self::java_command(class_name).args(parameters).spawn()
    }

    /// blocking call that gets the stdout
    pub fn get_output<I, S>(&self, class_name: &str, parameters: I) -> std::io::Result<String>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        let output = Self::java_command(class_name).args(parameters).output()?;
        String::from_utf8(output.stdout).map_err(|err| std::io::Error::new(std::io::ErrorKind::Other, err))
    }
}

lazy_static! {
    pub static ref SCALA_MICRO_BLOSSOM_RUNNER: ScalaMicroBlossomRunner = ScalaMicroBlossomRunner::new();

    // lock this when the scala is compiling verilator for simulation
    // this is a bug of SpinalHDL v1.9.3 and is already fixed in later version:
    // the temporarily compiled results are not in workspacePath but rather "tmp" relative path
    // this causes conflicts if running multiple simulations in parallel
    pub static ref SCALA_SIMULATION_LOCK: Mutex<()> = Mutex::new(());
}

pub fn env_is_set(name: &str) -> bool {
    match env::var(name) {
        Ok(value) => value != "",
        Err(_) => false,
    }
}

pub fn env_bool(name: &str, false_name: &str, default_value: bool) -> bool {
    if env_is_set(name) {
        assert!(!env_is_set(false_name), "bool environment variable conflicts");
        true
    } else if env_is_set(false_name) {
        false
    } else {
        default_value
    }
}

pub fn env_usize(name: &str, default: usize) -> usize {
    match env::var(name) {
        Ok(value) => value.parse().unwrap(),
        Err(_) => default,
    }
}

pub fn env_f64(name: &str, default: f64) -> f64 {
    match env::var(name) {
        Ok(value) => value.parse().unwrap(),
        Err(_) => default,
    }
}

pub fn random_name_16() -> String {
    rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(16)
        .map(char::from)
        .collect()
}

#[cfg(test)]
pub mod tests {
    use super::*;

    #[test]
    fn util_scala_micro_blossom_runner() {
        // cargo test util_scala_micro_blossom_runner -- --nocapture
        let help = SCALA_MICRO_BLOSSOM_RUNNER
            .get_output("microblossom.DualHost", vec!["--help"])
            .unwrap();
        println!("help: {help}");
    }
}
