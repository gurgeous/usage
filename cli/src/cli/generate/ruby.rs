use std::path::PathBuf;

use usage::miette::Result;
use usage::ruby::RubyOptions;
use usage_rs::Args;

use crate::cli::generate;

/// Generate Ruby parse tables from a usage spec
///
/// The generated file is read by the `usage-rb` gem. It contains static parse
/// tables, result classes, and a typed `parse` entry point.
#[derive(Args)]
#[usage(effect = "read")]
pub struct Ruby {
    /// A usage spec taken in as a file, use "-" to read from stdin
    #[usage(short, long)]
    file: Option<PathBuf>,

    /// File path where the generated Ruby source will be saved, or "-" for stdout
    #[usage(
        short,
        long,
        value_hint = usage_rs::ValueHint::FilePath,
        effect = "write"
    )]
    out_file: Option<PathBuf>,

    /// Module for the generated code (defaults to the spec's bin name)
    #[usage(short, long)]
    module: Option<String>,

    /// Raw string spec input
    #[usage(long, required_unless = "--file", overrides = "--file")]
    spec: Option<String>,
}

impl usage_rs::Run for Ruby {
    type Output = Result<()>;

    fn run(self) -> Self::Output {
        if let Some(module) = &self.module {
            if !usage::ruby::is_valid_module(module) {
                usage::miette::bail!(
                    "`--module {module}` is not a Ruby module path. Each `::`-separated name \
                     must start with an uppercase ASCII letter and contain only letters, digits, \
                     and underscores; `BEGIN` and `END` are reserved."
                );
            }
        }

        let spec = generate::file_or_spec(&self.file, &self.spec)?;
        let out = usage::ruby::generate(
            &spec,
            &RubyOptions {
                module: self.module,
            },
        );
        generate::write_or_stdout(self.out_file.as_deref(), &out)?;
        Ok(())
    }
}
