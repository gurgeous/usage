//! Emitting Ruby parse tables and typed result classes from a spec.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write as _;

use crate::case::{AsPascalCase, AsSnakeCase};
use crate::spec::unknown_flags::UnknownFlags;
use crate::{
    Spec, SpecArg, SpecChoices, SpecCommand, SpecDoubleDashChoices, SpecFlag, SpecFlagAction,
};

/// How to emit Ruby source.
#[derive(Debug, Clone, Default)]
pub struct RubyOptions {
    /// The generated module. Defaults to the spec's bin in PascalCase.
    pub module: Option<String>,
}

/// Turn a spec into one Ruby source file.
pub fn generate(spec: &Spec, opts: &RubyOptions) -> String {
    Emitter::new(spec, opts).run()
}

struct Named {
    key: String,
    number: u64,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FieldKind {
    Scalar,
    Boolean,
    Count,
    List,
}

struct Field {
    name: String,
    kind: FieldKind,
}

struct Emitted {
    named: Named,
    local: String,
    class: String,
    cmd: SpecCommand,
    flags: Vec<(SpecFlag, Named)>,
    args: Vec<(SpecArg, Named)>,
    clause_args: Vec<(SpecArg, Named)>,
    fields: HashMap<String, Field>,
    clause_field: Option<Field>,
    external_field: Option<Field>,
    clause_class: Option<String>,
    clause_fields: HashMap<String, Field>,
    subcommands: Vec<usize>,
    parent: Option<usize>,
    root: bool,
}

struct Emitter<'a> {
    spec: &'a Spec,
    module: String,
    taken: HashMap<String, u32>,
    command_names: HashMap<String, u32>,
    clause_names: HashMap<String, u32>,
    next_key: u64,
    out: String,
}

impl<'a> Emitter<'a> {
    fn new(spec: &'a Spec, opts: &RubyOptions) -> Self {
        let module = opts
            .module
            .clone()
            .filter(|name| is_valid_module(name))
            .unwrap_or_else(|| module_ident(&spec.bin));
        Self {
            spec,
            module,
            taken: HashMap::new(),
            command_names: HashMap::new(),
            clause_names: HashMap::new(),
            next_key: 0,
            out: String::new(),
        }
    }

    fn unique(&mut self, base: &str) -> String {
        let mut n = self.taken.get(base).copied().unwrap_or(0);
        loop {
            n += 1;
            let candidate = if n == 1 {
                base.to_string()
            } else {
                format!("{base}_{n}")
            };
            if !self.taken.contains_key(&candidate) {
                self.taken.insert(base.to_string(), n);
                self.taken.entry(candidate.clone()).or_insert(0);
                return candidate;
            }
        }
    }

    fn name(&mut self, prefix: &str, path: &[&str], own: &str) -> Named {
        let mut base = prefix.to_string();
        for part in path {
            let _ = write!(
                base,
                "_{}",
                AsSnakeCase(part).to_string().to_ascii_uppercase()
            );
        }
        let _ = write!(
            base,
            "_{}",
            AsSnakeCase(own).to_string().to_ascii_uppercase()
        );
        let key = self.unique(&base);
        self.next_key += 1;
        Named {
            key,
            number: self.next_key,
        }
    }

    fn unique_command_name(&mut self, path: &[&str]) -> String {
        let mut base = path
            .iter()
            .map(|part| constant_part(part))
            .collect::<String>();
        if base.is_empty() {
            base.push('X');
        }
        unique_pascal(&mut self.command_names, &base)
    }

    fn collect(
        &mut self,
        cmd: &SpecCommand,
        path: &[&str],
        parent: Option<usize>,
        out: &mut Vec<Emitted>,
    ) {
        let root = parent.is_none();
        let named = if root {
            self.next_key += 1;
            Named {
                key: self.unique("CMD_ROOT"),
                number: self.next_key,
            }
        } else {
            self.name("CMD", &path[..path.len() - 1], path[path.len() - 1])
        };
        let command_name = if root {
            String::new()
        } else {
            self.unique_command_name(path)
        };
        let class = if root {
            "CLI".into()
        } else {
            format!("{command_name}Command")
        };
        let local = format!("cmd_{}", named.key["CMD_".len()..].to_ascii_lowercase());
        let clause_class = cmd.clause.as_ref().map(|clause| {
            let base = format!("{command_name}{}Clause", constant_part(&clause.name));
            unique_pascal(&mut self.clause_names, &base)
        });
        let flags = cmd
            .flags
            .iter()
            .map(|flag| (flag.clone(), self.name("FLAG", path, &flag.name)))
            .collect();
        let args = cmd
            .args
            .iter()
            .map(|arg| (arg.clone(), self.name("ARG", path, &arg.name)))
            .collect();
        let clause_args = cmd
            .clause
            .as_ref()
            .map(|clause| {
                clause
                    .args
                    .iter()
                    .map(|arg| {
                        (
                            arg.clone(),
                            self.name("ARG", path, &format!("{}-{}", clause.name, arg.name)),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        let index = out.len();
        out.push(Emitted {
            named,
            local,
            class,
            cmd: cmd.clone(),
            flags,
            args,
            clause_args,
            fields: HashMap::new(),
            clause_field: None,
            external_field: None,
            clause_class,
            clause_fields: HashMap::new(),
            subcommands: Vec::new(),
            parent,
            root,
        });
        let mut children = Vec::new();
        for (name, sub) in &cmd.subcommands {
            if name != &sub.name {
                continue;
            }
            let mut child_path = path.to_vec();
            child_path.push(name);
            children.push(out.len());
            self.collect(sub, &child_path, Some(index), out);
        }
        out[index].subcommands = children;
    }

    fn run(mut self) -> String {
        let mut commands = Vec::new();
        self.collect(&self.spec.cmd.clone(), &[], None, &mut commands);
        resolve_fields(&mut commands);
        self.header();
        self.constants(&commands);
        self.tables(&commands);
        self.metadata(&commands);
        self.result_classes(&commands);
        self.parse(&commands);
        let end = self.out.trim_end().len();
        self.out.truncate(end);
        self.out.push_str("\nend\n");
        wrap_namespace(self.out, &self.module)
    }

    fn header(&mut self) {
        let _ = writeln!(
            self.out,
            "# Code generated by `usage generate ruby`. DO NOT EDIT.\n\
             # Static binding tables for {}. Regenerate them from the usage spec.\n\n\
             require \"usage\"\n\n\
             module {}",
            ruby_string(&self.spec.bin),
            self.module.rsplit("::").next().unwrap()
        );
        if let Some(version) = self
            .spec
            .version
            .as_ref()
            .or(self.spec.long_version.as_ref())
        {
            let _ = writeln!(self.out, "  VERSION = {}", ruby_string(version));
        }
        if let Some(version) = &self.spec.long_version {
            let _ = writeln!(self.out, "  LONG_VERSION = {}", ruby_string(version));
        }
        if self.spec.version.is_some() || self.spec.long_version.is_some() {
            self.out.push('\n');
        }
    }

    fn constants(&mut self, commands: &[Emitted]) {
        for command in commands {
            let _ = writeln!(
                self.out,
                "  {} = {}",
                command.named.key, command.named.number
            );
            for (_, named) in &command.flags {
                let _ = writeln!(self.out, "  {} = {}", named.key, named.number);
            }
            for (_, named) in command.args.iter().chain(command.clause_args.iter()) {
                let _ = writeln!(self.out, "  {} = {}", named.key, named.number);
            }
        }
        self.out.push('\n');
    }

    fn tables(&mut self, commands: &[Emitted]) {
        self.out.push_str("  ROOT = begin\n");
        let default = self.spec.default_subcommand.as_ref().and_then(|name| {
            let direct = || commands[0].subcommands.iter().map(|at| &commands[*at]);
            direct()
                .find(|entry| &entry.cmd.name == name)
                .or_else(|| {
                    direct().find(|entry| {
                        entry.cmd.aliases.contains(name) || entry.cmd.hidden_aliases.contains(name)
                    })
                })
                .map(|command| command.local.clone())
        });

        for (index, command) in commands.iter().enumerate().rev() {
            let local = &command.local;
            let mut fields = vec![
                ("name", ruby_string(&command.cmd.name)),
                ("key", command.named.key.clone()),
            ];
            let aliases = command
                .cmd
                .aliases
                .iter()
                .chain(command.cmd.hidden_aliases.iter())
                .cloned()
                .collect::<Vec<_>>();
            push_vec(&mut fields, "aliases", &aliases);
            if !command.flags.is_empty() {
                fields.push((
                    "flags",
                    multiline_array(
                        &command
                            .flags
                            .iter()
                            .map(|(flag, named)| flag_literal(flag, named, 8))
                            .collect::<Vec<_>>(),
                        6,
                    ),
                ));
            }
            if !command.args.is_empty() {
                fields.push((
                    "args",
                    multiline_array(
                        &command
                            .args
                            .iter()
                            .map(|(arg, named)| arg_literal(arg, named, 8))
                            .collect::<Vec<_>>(),
                        6,
                    ),
                ));
            }
            if let Some(clause) = &command.cmd.clause {
                let mut clause_fields = vec![
                    ("key", command.named.key.clone()),
                    ("name", ruby_string(&clause.name)),
                    ("sep", ruby_string(&clause.separator)),
                ];
                clause_fields.push((
                    "args",
                    multiline_array(
                        &command
                            .clause_args
                            .iter()
                            .map(|(arg, named)| arg_literal(arg, named, 10))
                            .collect::<Vec<_>>(),
                        8,
                    ),
                ));
                fields.push(("clause", ruby_call("Usage::Clause", &clause_fields, 6)));
            }
            if !command.subcommands.is_empty() {
                fields.push((
                    "cmds",
                    format!(
                        "[{}]",
                        command
                            .subcommands
                            .iter()
                            .map(|at| commands[*at].local.clone())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                ));
            }
            if effective_unknown_flags(self.spec, commands, index) == UnknownFlags::Error {
                fields.push(("unknown_flags", ":error".into()));
            }
            push_true(
                &mut fields,
                "external_cmd",
                command.cmd.external_subcommand,
            );
            push_true(
                &mut fields,
                "arg_required_else_help",
                command.cmd.arg_required_else_help,
            );
            push_true(
                &mut fields,
                "disable_help_flag",
                command.cmd.disable_help_flag,
            );
            push_true(
                &mut fields,
                "disable_help_cmd",
                command.cmd.disable_help_subcommand,
            );
            push_true(
                &mut fields,
                "disable_version_flag",
                command.cmd.disable_version_flag,
            );
            push_true(
                &mut fields,
                "cmd_negates_requirements",
                command.cmd.subcommand_negates_reqs,
            );
            push_true(
                &mut fields,
                "args_conflict_with_cmds",
                command.cmd.args_conflicts_with_subcommands,
            );
            push_true(
                &mut fields,
                "cmd_precedence_over_arg",
                command.cmd.subcommand_precedence_over_arg,
            );
            push_true(
                &mut fields,
                "allow_missing_positional",
                command.cmd.allow_missing_positional,
            );
            push_true(
                &mut fields,
                "dont_delimit_trailing_values",
                command.cmd.dont_delimit_trailing_values,
            );
            if command.root {
                if let Some(default) = &default {
                    fields.push(("default_cmd", default.clone()));
                }
                push_true(
                    &mut fields,
                    "version",
                    self.spec.version.is_some() || self.spec.long_version.is_some(),
                );
            }
            let literal = ruby_call("Usage::Command", &fields, 4);
            if command.root {
                let _ = writeln!(self.out, "    {literal}");
            } else {
                let _ = writeln!(self.out, "    {local} = {literal}");
            }
        }
        self.out.push_str("  end\n\n");
    }

    fn metadata(&mut self, commands: &[Emitted]) {
        let mut by_key = BTreeMap::new();
        for command in commands {
            for (flag, named) in &command.flags {
                by_key.insert(named.number, flag_meta(flag, named, command, commands));
            }
            for (arg, named) in command.args.iter().chain(command.clause_args.iter()) {
                by_key.insert(named.number, arg_meta(arg, named, command, commands));
            }
        }
        let _ = writeln!(self.out, "  META = Usage::Metadata.new(\n    [");
        for key in 1..=self.next_key {
            let value = by_key.get(&key).map(String::as_str).unwrap_or("nil");
            let _ = writeln!(self.out, "      {value},");
        }
        self.out.push_str("    ],\n  )\n\n");
    }

    fn result_classes(&mut self, commands: &[Emitted]) {
        for command in commands {
            let mut fields = command
                .flags
                .iter()
                .map(|(_, named)| &command.fields[&named.key])
                .chain(
                    command
                        .args
                        .iter()
                        .map(|(_, named)| &command.fields[&named.key]),
                )
                .collect::<Vec<_>>();
            fields.extend(command.clause_field.iter());
            fields.extend(command.external_field.iter());
            for at in &command.subcommands {
                let child = &commands[*at];
                fields.push(&command.fields[&child.named.key]);
            }
            let _ = writeln!(self.out, "  class {}", command.class);
            if !fields.is_empty() {
                let _ = writeln!(
                    self.out,
                    "    attr_accessor {}",
                    fields
                        .iter()
                        .map(|field| format!(":{}", field.name))
                        .collect::<Vec<_>>()
                        .join(", ")
                );
            }
            result_initializer(&mut self.out, &fields);
            self.out.push_str("  end\n\n");

            if command.cmd.clause.is_some() {
                let fields = command
                    .clause_args
                    .iter()
                    .map(|(_, named)| &command.clause_fields[&named.key])
                    .collect::<Vec<_>>();
                let _ = writeln!(
                    self.out,
                    "  class {}",
                    command.clause_class.as_ref().unwrap()
                );
                if !fields.is_empty() {
                    let _ = writeln!(
                        self.out,
                        "    attr_accessor {}",
                        fields
                            .iter()
                            .map(|field| format!(":{}", field.name))
                            .collect::<Vec<_>>()
                            .join(", ")
                    );
                }
                result_initializer(&mut self.out, &fields);
                self.out.push_str("  end\n\n");
            }
        }
    }

    fn parse(&mut self, commands: &[Emitted]) {
        let root = &commands[0];
        if self.spec.multicall {
            self.out
                .push_str("  def self.parse(args = ARGV, argv0: nil)\n");
            let _ = writeln!(
                self.out,
                "    args = Usage::Parser.rewrite_multicall(argv0, args, {}, {})",
                ruby_string(&self.spec.name),
                ruby_string(&self.spec.bin)
            );
        } else {
            self.out.push_str("  def self.parse(args = ARGV)\n");
        }
        self.out
            .push_str("    parsed = Usage::Parser.new(ROOT, META, args).parse\n");
        let _ = writeln!(self.out, "    cli = {}.new", root.class);
        self.out.push_str("    cmds = { CMD_ROOT => cli }\n");
        if commands.len() > 1 {
            self.out
                .push_str("\n    parsed.cmd_keys.drop(1).each do |key|\n      case key\n");
            for command in commands.iter().skip(1) {
                let parent = command.parent.unwrap();
                let parent_key = &commands[parent].named.key;
                let _ = writeln!(
                    self.out,
                    "      when {}\n        cmds.fetch({}).{} = cmds[key] = {}.new",
                    command.named.key,
                    parent_key,
                    commands[parent].fields[&command.named.key].name,
                    command.class
                );
            }
            self.out.push_str("      end\n    end\n");
        }
        if commands
            .iter()
            .any(|command| !command.flags.is_empty() || !command.args.is_empty())
        {
            self.out
                .push_str("\n    parsed.values.each do |key, values|\n      case key\n");
            for command in commands {
                let owner = &command.named.key;
                for (_, named) in &command.flags {
                    let field = &command.fields[&named.key];
                    let _ = writeln!(
                        self.out,
                        "      when {}\n        cmds.fetch({}).{} = {}",
                        named.key,
                        owner,
                        field.name,
                        field.kind.parsed_value()
                    );
                }
                for (_, named) in &command.args {
                    let field = &command.fields[&named.key];
                    let _ = writeln!(
                        self.out,
                        "      when {}\n        cmds.fetch({}).{} = {}",
                        named.key,
                        owner,
                        field.name,
                        field.kind.parsed_value()
                    );
                }
            }
            self.out.push_str("      end\n    end\n");
        }
        for command in commands.iter().filter(|entry| entry.cmd.clause.is_some()) {
            let field = &command.clause_field.as_ref().unwrap().name;
            let class = command.clause_class.as_ref().unwrap();
            let _ = writeln!(
                self.out,
                "\n    parsed.clauses.fetch({}, []).each do |instance|\n      item = {class}.new",
                command.named.key
            );
            for (_, named) in &command.clause_args {
                let arg_field = &command.clause_fields[&named.key];
                let _ = writeln!(
                    self.out,
                    "      if (values = instance[{}])\n        item.{} = {}\n      end",
                    named.key,
                    arg_field.name,
                    arg_field.kind.parsed_value()
                );
            }
            let _ = writeln!(
                self.out,
                "      cmds.fetch({}).{field} << item\n    end",
                command.named.key
            );
        }
        if commands.iter().any(|entry| entry.cmd.external_subcommand) {
            self.out
                .push_str("\n    unless parsed.external.empty?\n      case parsed.cmd_keys.last\n");
            for command in commands
                .iter()
                .filter(|entry| entry.cmd.external_subcommand)
            {
                let field = &command.external_field.as_ref().unwrap().name;
                let _ = writeln!(
                    self.out,
                    "      when {}\n        cmds.fetch({}).{field} = parsed.external.dup",
                    command.named.key, command.named.key
                );
            }
            self.out.push_str("      end\n    end\n");
        }
        self.out.push_str("\n    cli\n  end\n");
    }
}

impl FieldKind {
    fn flag(flag: &SpecFlag) -> Self {
        if flag.count {
            Self::Count
        } else if flag.arg.is_none() {
            Self::Boolean
        } else if flag.var || flag.arg.as_ref().is_some_and(|arg| arg.var) {
            Self::List
        } else {
            Self::Scalar
        }
    }

    fn arg(arg: &SpecArg) -> Self {
        if arg.var {
            Self::List
        } else {
            Self::Scalar
        }
    }

    fn default(self) -> Option<&'static str> {
        match self {
            Self::Scalar => None,
            Self::Boolean => Some("false"),
            Self::Count => Some("0"),
            Self::List => Some("[]"),
        }
    }

    fn parsed_value(self) -> &'static str {
        match self {
            Self::Scalar => "values.last",
            Self::Boolean => "parsed.boolean(key)",
            Self::Count => "parsed.occurrences(key)",
            Self::List => "values.dup",
        }
    }
}

fn resolve_fields(commands: &mut [Emitted]) {
    let layouts = commands
        .iter()
        .map(|command| {
            let mut taken = HashSet::new();
            let mut fields = HashMap::new();
            for (flag, named) in &command.flags {
                fields.insert(
                    named.key.clone(),
                    Field {
                        name: field_name(&flag.name, "flag", &mut taken),
                        kind: FieldKind::flag(flag),
                    },
                );
            }
            for (arg, named) in &command.args {
                fields.insert(
                    named.key.clone(),
                    Field {
                        name: field_name(&arg.name, "argument", &mut taken),
                        kind: FieldKind::arg(arg),
                    },
                );
            }
            let clause_field = command.cmd.clause.as_ref().map(|clause| Field {
                name: field_name(&clause.name, "clause", &mut taken),
                kind: FieldKind::List,
            });
            let external_field = command.cmd.external_subcommand.then(|| Field {
                name: field_name("external", "external", &mut taken),
                kind: FieldKind::List,
            });
            for at in &command.subcommands {
                let child = &commands[*at];
                fields.insert(
                    child.named.key.clone(),
                    Field {
                        name: field_name(&child.cmd.name, "command", &mut taken),
                        kind: FieldKind::Scalar,
                    },
                );
            }

            let mut clause_taken = HashSet::new();
            let clause_fields = command
                .clause_args
                .iter()
                .map(|(arg, named)| {
                    (
                        named.key.clone(),
                        Field {
                            name: field_name(&arg.name, "argument", &mut clause_taken),
                            kind: FieldKind::arg(arg),
                        },
                    )
                })
                .collect();
            (fields, clause_field, external_field, clause_fields)
        })
        .collect::<Vec<_>>();

    for (command, (fields, clause_field, external_field, clause_fields)) in
        commands.iter_mut().zip(layouts)
    {
        command.fields = fields;
        command.clause_field = clause_field;
        command.external_field = external_field;
        command.clause_fields = clause_fields;
    }
}

fn kwargs(fields: &[(&str, String)]) -> String {
    fields
        .iter()
        .map(|(key, value)| format!("{key}: {value}"))
        .collect::<Vec<_>>()
        .join(", ")
}

fn ruby_call(name: &str, fields: &[(&str, String)], indent: usize) -> String {
    let field_indent = " ".repeat(indent + 2);
    let closing_indent = " ".repeat(indent);
    let mut out = format!("{name}.new(\n");
    for (key, value) in fields {
        let _ = writeln!(out, "{field_indent}{key}: {value},");
    }
    let _ = write!(out, "{closing_indent})");
    out
}

fn ruby_hash(fields: &[(&str, String)], indent: usize) -> String {
    let field_indent = " ".repeat(indent + 2);
    let closing_indent = " ".repeat(indent);
    let mut out = String::from("{\n");
    for (key, value) in fields {
        let _ = writeln!(out, "{field_indent}{key}: {value},");
    }
    let _ = write!(out, "{closing_indent}}}");
    out
}

fn multiline_array(values: &[String], indent: usize) -> String {
    let value_indent = " ".repeat(indent + 2);
    let closing_indent = " ".repeat(indent);
    let mut out = String::from("[\n");
    for value in values {
        let _ = writeln!(out, "{value_indent}{value},");
    }
    let _ = write!(out, "{closing_indent}]");
    out
}

fn result_initializer(out: &mut String, fields: &[&Field]) {
    let initialized = fields
        .iter()
        .filter(|field| field.kind.default().is_some())
        .copied()
        .collect::<Vec<_>>();
    if initialized.is_empty() {
        return;
    }

    out.push_str("\n    def initialize\n");
    for kind in [FieldKind::Boolean, FieldKind::Count] {
        let default = kind.default().unwrap();
        let names = initialized
            .iter()
            .filter(|field| field.kind == kind)
            .map(|field| format!("@{}", field.name))
            .collect::<Vec<_>>();
        if !names.is_empty() {
            let _ = writeln!(out, "      {} = {default}", names.join(" = "));
        }
    }
    let arrays = initialized
        .iter()
        .filter(|field| field.kind == FieldKind::List)
        .map(|field| format!("@{}", field.name))
        .collect::<Vec<_>>();
    match arrays.as_slice() {
        [] => {}
        [field] => {
            let _ = writeln!(out, "      {field} = []");
        }
        _ => {
            let defaults = vec!["[]"; arrays.len()].join(", ");
            let _ = writeln!(out, "      {} = {defaults}", arrays.join(", "));
        }
    }
    out.push_str("    end\n");
}

fn push_true(fields: &mut Vec<(&'static str, String)>, key: &'static str, value: bool) {
    if value {
        fields.push((key, "true".into()));
    }
}

fn push_vec(fields: &mut Vec<(&'static str, String)>, key: &'static str, values: &[String]) {
    if !values.is_empty() {
        fields.push((key, ruby_array(values)));
    }
}

fn ruby_array(values: &[String]) -> String {
    format!(
        "[{}]",
        values
            .iter()
            .map(|value| ruby_string(value))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn key_array(values: &[String]) -> String {
    format!("[{}]", values.join(", "))
}

fn flag_literal(flag: &SpecFlag, named: &Named, indent: usize) -> String {
    let mut fields = vec![
        ("key", named.key.clone()),
        ("name", ruby_string(&flag.name)),
    ];
    push_vec(&mut fields, "longs", &flag.long);
    push_vec(&mut fields, "hidden_longs", &flag.hidden_aliases);
    if !flag.short.is_empty() {
        fields.push((
            "shorts",
            ruby_array(&flag.short.iter().map(char::to_string).collect::<Vec<_>>()),
        ));
    }
    if !flag.hidden_short_aliases.is_empty() {
        fields.push((
            "hidden_shorts",
            ruby_array(
                &flag
                    .hidden_short_aliases
                    .iter()
                    .map(char::to_string)
                    .collect::<Vec<_>>(),
            ),
        ));
    }
    if let Some(negate) = &flag.negate {
        fields.push(("negate", ruby_string(negate.trim_start_matches('-'))));
    }
    push_true(&mut fields, "takes_value", flag.arg.is_some());
    push_true(&mut fields, "value_optional", flag.value_optional);
    push_true(&mut fields, "bool_value", flag.bool_value);
    let action = match flag.action {
        SpecFlagAction::Set => None,
        SpecFlagAction::Help => Some(":help"),
        SpecFlagAction::HelpShort => Some(":help_short"),
        SpecFlagAction::HelpLong => Some(":help_long"),
        SpecFlagAction::HelpAll => Some(":help_all"),
        SpecFlagAction::Version => Some(":version"),
    };
    if let Some(action) = action {
        fields.push(("action", action.into()));
    }
    if let Some(arg) = flag.arg.as_ref().filter(|arg| arg.var) {
        fields.push(("variadic", "true".into()));
        if let Some(max) = arg.var_max {
            fields.push(("var_max", clamp(max).to_string()));
        }
    }
    push_true(
        &mut fields,
        "allow_hyphen_values",
        flag.allow_hyphen_values(),
    );
    if let Some(arg) = &flag.arg {
        push_true(
            &mut fields,
            "allow_negative_numbers",
            arg.allow_negative_numbers,
        );
        if let Some(value) = &arg.value_terminator {
            fields.push(("value_terminator", ruby_string(value)));
        }
        if let Some(value) = arg.delimiter {
            fields.push(("delimiter", ruby_string(&value.to_string())));
        }
    }
    push_true(&mut fields, "require_equals", flag.require_equals);
    if let Some(value) = &flag.default_missing {
        fields.push(("default_missing", ruby_string(value)));
    }
    push_true(&mut fields, "global", flag.global);
    ruby_call("Usage::Flag", &fields, indent)
}

fn arg_literal(arg: &SpecArg, named: &Named, indent: usize) -> String {
    let mut fields = vec![("key", named.key.clone()), ("name", ruby_string(&arg.name))];
    if let Some(value) = &arg.sigil {
        fields.push(("sigil", ruby_string(value)));
    }
    push_true(&mut fields, "required", arg.required);
    push_true(&mut fields, "variadic", arg.var);
    if arg.var {
        if let Some(max) = arg.var_max {
            fields.push(("var_max", clamp(max).to_string()));
        }
    }
    push_true(
        &mut fields,
        "allow_negative_numbers",
        arg.allow_negative_numbers,
    );
    if let Some(value) = &arg.value_terminator {
        fields.push(("value_terminator", ruby_string(value)));
    }
    if let Some(value) = arg.delimiter {
        fields.push(("delimiter", ruby_string(&value.to_string())));
    }
    let double_dash = match arg.double_dash {
        SpecDoubleDashChoices::Required => Some(":required"),
        SpecDoubleDashChoices::Preserve => Some(":preserve"),
        SpecDoubleDashChoices::Automatic => Some(":automatic"),
        _ => None,
    };
    if let Some(value) = double_dash {
        fields.push(("double_dash", value.into()));
    }
    ruby_call("Usage::Argument", &fields, indent)
}

fn flag_meta(flag: &SpecFlag, named: &Named, owner: &Emitted, commands: &[Emitted]) -> String {
    let mut fields = vec![
        ("key", named.key.clone()),
        ("name", ruby_string(&flag.name)),
        ("flag", "true".into()),
    ];
    push_true(
        &mut fields,
        "reject_duplicate",
        !owner.cmd.args_override_self
            && !flag.var
            && !flag.count
            && !flag.arg.as_ref().is_some_and(|arg| arg.var),
    );
    push_true(&mut fields, "required", flag.required);
    push_true(&mut fields, "boolean", flag.arg.is_none());
    if let Some(long) = flag.long.first() {
        fields.push(("spelling", ruby_string(&format!("--{long}"))));
    } else if let Some(short) = flag.short.first() {
        fields.push(("spelling", ruby_string(&format!("-{short}"))));
    }
    if let Some(arg) = &flag.arg {
        fields.push(("value_name", ruby_string(&arg.name)));
    }
    if let Some(choices) = flag.arg.as_ref().and_then(|arg| arg.choices.as_ref()) {
        choice_fields(&mut fields, choices);
    }
    let default = if flag.default.is_empty() {
        flag.arg
            .as_ref()
            .map(|arg| &arg.default)
            .unwrap_or(&flag.default)
    } else {
        &flag.default
    };
    push_vec(&mut fields, "default", default);
    if let Some(value) = &flag.env {
        fields.push(("env", ruby_string(value)));
    }
    push_vec(&mut fields, "env_fallback", &flag.env_fallback);
    push_vec(&mut fields, "deprecated_env", &flag.deprecated_env);
    let min = flag
        .arg
        .as_ref()
        .filter(|arg| arg.var)
        .and_then(|arg| arg.var_min)
        .or(flag.var_min);
    if let Some(value) = min {
        fields.push(("var_min", clamp(value).to_string()));
    }
    if let Some(value) = flag.var_max {
        fields.push(("var_max", clamp(value).to_string()));
    }
    if let Some(value) = flag.arg.as_ref().and_then(|arg| arg.validate.as_ref()) {
        fields.push(("validate", ruby_string(value)));
    }
    if let Some(value) = flag
        .arg
        .as_ref()
        .and_then(|arg| arg.validate_error.as_ref())
    {
        fields.push(("validate_error", ruby_string(value)));
    }
    for (label, names) in [
        ("conflicts", &flag.conflicts),
        ("overrides", &flag.overrides),
        ("required_unless", &flag.required_unless),
        ("required_unless_all", &flag.required_unless_all),
        ("required_if", &flag.required_if),
        ("requires", &flag.requires),
    ] {
        let keys = resolve_relationship(names, owner, commands);
        if !keys.is_empty() {
            fields.push((label, key_array(&keys)));
        }
    }
    push_conditions(
        &mut fields,
        "required_if_eq",
        &flag.required_if_eq,
        owner,
        commands,
    );
    push_conditions(
        &mut fields,
        "required_if_eq_all",
        &flag.required_if_eq_all,
        owner,
        commands,
    );
    let requires_if = flag
        .requires_if
        .iter()
        .filter_map(|condition| {
            resolve_relationship(std::slice::from_ref(&condition.requires), owner, commands)
                .into_iter()
                .next()
                .map(|key| format!("{{ value: {}, key: {key} }}", ruby_string(&condition.value)))
        })
        .collect::<Vec<_>>();
    if !requires_if.is_empty() {
        fields.push(("requires_if", format!("[{}]", requires_if.join(", "))));
    }
    let default_if = flag
        .default_if
        .iter()
        .filter_map(|condition| {
            resolve_relationship(std::slice::from_ref(&condition.selector), owner, commands)
                .into_iter()
                .next()
                .map(|key| {
                    let mut fields = vec![("key", key), ("value", ruby_string(&condition.value))];
                    if let Some(when) = &condition.when {
                        fields.push(("when", ruby_string(when)));
                    }
                    format!("{{ {} }}", kwargs(&fields))
                })
        })
        .collect::<Vec<_>>();
    if !default_if.is_empty() {
        fields.push(("default_if", format!("[{}]", default_if.join(", "))));
    }
    ruby_hash(&fields, 6)
}

fn arg_meta(arg: &SpecArg, named: &Named, owner: &Emitted, commands: &[Emitted]) -> String {
    let mut fields = vec![("key", named.key.clone()), ("name", ruby_string(&arg.name))];
    push_true(&mut fields, "required", arg.required);
    if let Some(choices) = &arg.choices {
        choice_fields(&mut fields, choices);
    }
    push_vec(&mut fields, "default", &arg.default);
    if let Some(value) = &arg.env {
        fields.push(("env", ruby_string(value)));
    }
    push_vec(&mut fields, "env_fallback", &arg.env_fallback);
    push_vec(&mut fields, "deprecated_env", &arg.deprecated_env);
    if let Some(value) = arg.var_min {
        fields.push(("var_min", clamp(value).to_string()));
    }
    if let Some(value) = &arg.validate {
        fields.push(("validate", ruby_string(value)));
    }
    if let Some(value) = &arg.validate_error {
        fields.push(("validate_error", ruby_string(value)));
    }
    for (label, names) in [
        ("conflicts", &arg.conflicts),
        ("requires", &arg.requires),
        ("required_if", &arg.required_if),
        ("required_unless", &arg.required_unless),
        ("required_unless_all", &arg.required_unless_all),
    ] {
        let keys = resolve_relationship(names, owner, commands);
        if !keys.is_empty() {
            fields.push((label, key_array(&keys)));
        }
    }
    push_conditions(
        &mut fields,
        "required_if_eq",
        &arg.required_if_eq,
        owner,
        commands,
    );
    push_conditions(
        &mut fields,
        "required_if_eq_all",
        &arg.required_if_eq_all,
        owner,
        commands,
    );
    ruby_hash(&fields, 6)
}

fn push_conditions(
    fields: &mut Vec<(&'static str, String)>,
    label: &'static str,
    conditions: &[crate::SpecRequiredIfEq],
    owner: &Emitted,
    commands: &[Emitted],
) {
    let values = conditions
        .iter()
        .filter_map(|condition| {
            resolve_relationship(std::slice::from_ref(&condition.selector), owner, commands)
                .into_iter()
                .next()
                .map(|key| format!("{{ key: {key}, value: {} }}", ruby_string(&condition.value)))
        })
        .collect::<Vec<_>>();
    if !values.is_empty() {
        fields.push((label, format!("[{}]", values.join(", "))));
    }
}

fn choice_fields(fields: &mut Vec<(&'static str, String)>, choices: &SpecChoices) {
    fields.push(("choices", ruby_array(&visible_choices(choices))));
    fields.push(("accepted_choices", ruby_array(&accepted_choices(choices))));
    push_true(fields, "ignore_case", choices.ignore_case);
    push_true(fields, "allow_unknown_choices", !choices.strict);
}

fn visible_choices(choices: &SpecChoices) -> Vec<String> {
    choices
        .choices
        .iter()
        .filter(|value| {
            !choices
                .details
                .iter()
                .any(|choice| choice.value == value.as_str() && choice.hide)
        })
        .chain(choices.details.iter().flat_map(|choice| {
            choice
                .aliases
                .iter()
                .filter(|alias| !alias.hide)
                .map(|alias| &alias.value)
        }))
        .cloned()
        .collect()
}

fn accepted_choices(choices: &SpecChoices) -> Vec<String> {
    choices
        .choices
        .iter()
        .chain(
            choices
                .details
                .iter()
                .flat_map(|choice| choice.aliases.iter().map(|alias| &alias.value)),
        )
        .cloned()
        .collect()
}

fn resolve_relationship(names: &[String], owner: &Emitted, commands: &[Emitted]) -> Vec<String> {
    names
        .iter()
        .filter_map(|name| {
            let mut found = match_flag(owner, name, false);
            if found.is_none() && !name.starts_with('-') {
                found = owner
                    .args
                    .iter()
                    .chain(owner.clause_args.iter())
                    .find(|(arg, _)| arg.name == *name)
                    .map(|(_, named)| named.key.clone());
            }
            if found.is_none() {
                let path = &owner.cmd.full_cmd;
                for depth in (0..path.len()).rev() {
                    let ancestor = commands.iter().find(|entry| {
                        entry.cmd.full_cmd.len() == depth && entry.cmd.full_cmd[..] == path[..depth]
                    });
                    if let Some(key) = ancestor.and_then(|entry| match_flag(entry, name, true)) {
                        found = Some(key);
                        break;
                    }
                }
            }
            found
        })
        .collect()
}

fn match_flag(command: &Emitted, name: &str, globals_only: bool) -> Option<String> {
    let eligible = |flag: &SpecFlag| !globals_only || flag.global;
    let (long, short, bare) = if let Some(value) = name.strip_prefix("--") {
        (Some(value), None, None)
    } else if let Some(value) = name.strip_prefix('-') {
        let mut chars = value.chars();
        match (chars.next(), chars.next()) {
            (Some(value), None) => (None, Some(value), None),
            _ => (None, None, None),
        }
    } else {
        (None, None, Some(name))
    };
    if let Some((_, named)) = command.flags.iter().find(|(flag, _)| {
        eligible(flag)
            && match (long, short, bare) {
                (Some(value), _, _) => flag.long.iter().any(|item| item == value),
                (_, Some(value), _) => flag.short.contains(&value),
                (_, _, Some(value)) => flag.name == value,
                _ => false,
            }
    }) {
        return Some(named.key.clone());
    }
    command
        .flags
        .iter()
        .find(|(flag, _)| eligible(flag) && flag.negate.as_deref() == Some(name))
        .map(|(_, named)| named.key.clone())
}

fn effective_unknown_flags(spec: &Spec, commands: &[Emitted], at: usize) -> UnknownFlags {
    let path = &commands[at].cmd.full_cmd;
    for depth in (0..=path.len()).rev() {
        let ancestor = commands.iter().find(|entry| {
            entry.cmd.full_cmd.len() == depth && entry.cmd.full_cmd[..] == path[..depth]
        });
        if let Some(mode) = ancestor.and_then(|entry| entry.cmd.unknown_flags) {
            return mode;
        }
    }
    spec.unknown_flags.unwrap_or_default()
}

fn field_name(name: &str, kind: &str, taken: &mut HashSet<String>) -> String {
    let mut base = AsSnakeCase(name).to_string();
    if base.is_empty() || base.starts_with(|value: char| value.is_ascii_digit()) {
        base = format!("x_{base}");
    }
    if taken.insert(base.clone()) {
        return base;
    }
    let kinded = format!("{base}_{kind}");
    if taken.insert(kinded.clone()) {
        return kinded;
    }
    for index in 2.. {
        let candidate = format!("{kinded}_{index}");
        if taken.insert(candidate.clone()) {
            return candidate;
        }
    }
    unreachable!()
}

fn constant_part(name: &str) -> String {
    let mut value = AsPascalCase(name).to_string();
    if value.is_empty() || value.starts_with(|character: char| character.is_ascii_digit()) {
        value.insert(0, 'X');
    }
    value
}

fn unique_pascal(taken: &mut HashMap<String, u32>, base: &str) -> String {
    let mut number = taken.get(base).copied().unwrap_or(0);
    loop {
        number += 1;
        let candidate = if number == 1 {
            base.to_string()
        } else {
            format!("{base}{number}")
        };
        if !taken.contains_key(&candidate) {
            taken.insert(base.to_string(), number);
            taken.entry(candidate.clone()).or_insert(0);
            return candidate;
        }
    }
}

/// Whether a name can be used as one generated Ruby module constant.
pub fn is_valid_module(name: &str) -> bool {
    !name.is_empty() && name.split("::").all(is_valid_module_segment)
}

fn is_valid_module_segment(name: &str) -> bool {
    if matches!(name, "BEGIN" | "END") {
        return false;
    }
    let mut chars = name.chars();
    chars.next().is_some_and(|value| value.is_ascii_uppercase())
        && chars.all(|value| value.is_ascii_alphanumeric() || value == '_')
}

fn wrap_namespace(source: String, module: &str) -> String {
    let modules = module.split("::").collect::<Vec<_>>();
    let outers = &modules[..modules.len() - 1];
    if outers.is_empty() {
        return source;
    }

    let marker = format!("module {}\n", modules.last().unwrap());
    let at = source.find(&marker).expect("generated module declaration");
    let (preamble, body) = source.split_at(at);
    let mut out = String::with_capacity(source.len() + outers.len() * 16);
    out.push_str(preamble);
    for (depth, name) in outers.iter().enumerate() {
        let _ = writeln!(out, "{}module {name}", "  ".repeat(depth));
    }
    let indent = "  ".repeat(outers.len());
    for line in body.split_inclusive('\n') {
        if line != "\n" {
            out.push_str(&indent);
        }
        out.push_str(line);
    }
    for depth in (0..outers.len()).rev() {
        let _ = writeln!(out, "{}end", "  ".repeat(depth));
    }
    out
}

fn module_ident(bin: &str) -> String {
    let value = AsPascalCase(bin).to_string();
    if is_valid_module(&value) {
        value
    } else {
        format!("CLI{value}")
    }
}

fn ruby_string(value: &str) -> String {
    let mut out = String::from("\"");
    let mut chars = value.chars().peekable();
    while let Some(value) = chars.next() {
        match value {
            '\"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '#' if chars.peek() == Some(&'{') => out.push_str("\\#"),
            value if (value as u32) < 0x20 || value as u32 == 0x7f => {
                let _ = write!(out, "\\x{:02x}", value as u32);
            }
            value => out.push(value),
        }
    }
    out.push('\"');
    out
}

fn clamp(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ruby(kdl: &str) -> String {
        generate(&kdl.parse().unwrap(), &RubyOptions::default())
    }

    #[test]
    fn emits_tables_results_and_parse() {
        insta::assert_snapshot!(ruby(
            r#"
            name "ex"
            bin "ex"
            version "1.2.3"
            flag "-v --verbose" global=#true
            flag "--jobs <n>" env="JOBS" default="2"
            arg "[file]"
            cmd "install" {
                alias "i"
                flag "-f --force"
                arg "<pkg>"
            }
        "#
        ));
    }

    #[test]
    fn identifiers_are_valid_and_distinct() {
        let out = ruby(
            r#"
            name "odd"
            bin "7-zip"
            flag "--class"
            flag "--foo-bar"
            arg "[foo_bar]"
            cmd "foo-bar"
            cmd "foo_bar"
        "#,
        );
        assert!(out.contains("module CLI7Zip"));
        assert!(out.contains("attr_accessor :class"));
        assert!(out.contains("foo_bar_argument"));
        assert!(out.contains("CMD_FOO_BAR_2"));
        assert!(out.contains("class FooBar2Command"));
    }

    #[test]
    fn class_names_are_valid_and_distinct() {
        let out = ruby(
            r#"
            name "ex"
            bin "ex"
            clause "2things" separator=":::" { arg "<value>" }
            cmd "2fa"
            cmd "+"
            cmd "foo" { cmd "bar" }
            cmd "foo-bar"
            cmd "foo-bar2"
        "#,
        );
        let classes = out
            .lines()
            .filter_map(|line| line.trim().strip_prefix("class "))
            .collect::<Vec<_>>();
        let mut distinct = HashSet::new();
        for class in &classes {
            assert!(
                class.starts_with(|character: char| character.is_ascii_uppercase()),
                "invalid class {class:?}:\n{out}"
            );
            assert!(distinct.insert(*class), "duplicate class {class:?}:\n{out}");
        }
        assert!(out.contains("class X2faCommand"), "{out}");
        assert!(out.contains("class XCommand"), "{out}");
        assert!(out.contains("class X2thingsClause"), "{out}");
    }

    #[test]
    fn same_named_clauses_keep_their_owners_fields() {
        let out = ruby(
            r#"
            name "ex"
            bin "ex"
            cmd "a" {
                flag "--items"
                clause "items" separator=":::" { arg "<x>" }
            }
            cmd "b" {
                clause "items" separator=":::" { arg "<x>" }
            }
        "#,
        );
        assert!(
            out.contains("cmds.fetch(CMD_A).items_clause << item"),
            "{out}"
        );
        assert!(out.contains("cmds.fetch(CMD_B).items << item"), "{out}");
    }

    #[test]
    fn routes_defaults_inheritance_and_clauses() {
        insta::assert_snapshot!(ruby(
            r#"
            name "ex"
            bin "ex"
            unknown_flags "error"
            default_subcommand "run"
            cmd "run" {
                flag "--needs-task" requires="task"
                clause "items" separator=":::" {
                    arg "<task>"
                }
            }
            cmd "exec" unknown_flags="value" {
                cmd "nested" {}
            }
        "#
        ));
    }

    #[test]
    fn escapes_ruby_interpolation_and_controls() {
        assert_eq!(ruby_string("a#{b}\n\u{7f}"), r#""a\#{b}\n\x7f""#);
    }

    #[test]
    fn validates_explicit_modules() {
        assert!(is_valid_module("MyCLI"));
        assert!(is_valid_module("Acme::Tools::CLI"));
        assert!(!is_valid_module("my_cli"));
        assert!(!is_valid_module("Acme::::CLI"));
        assert!(!is_valid_module("BEGIN"));
        assert!(!is_valid_module("Acme::END"));
    }

    #[test]
    fn emits_nested_modules() {
        let spec: Spec = "name \"ex\"\nbin \"ex\"\n".parse().unwrap();
        let out = generate(
            &spec,
            &RubyOptions {
                module: Some("Acme::Tools::CLI".into()),
            },
        );
        assert!(
            out.contains("module Acme\n  module Tools\n    module CLI\n"),
            "{out}"
        );
        assert!(out.ends_with("    end\n  end\nend\n"), "{out}");
        assert!(
            out.lines().all(|line| !line.ends_with(' ')),
            "nested modules emitted trailing whitespace:\n{out}"
        );
    }

    #[test]
    fn accessor_names_are_not_rewritten() {
        let out = ruby("name \"ex\"\nbin \"ex\"\nflag \"--send\"\narg \"[object-id]\"\n");
        assert!(out.contains("attr_accessor :send, :object_id"), "{out}");
    }

    #[test]
    fn an_empty_cli_emits_no_empty_case() {
        let out = ruby("name \"ex\"\nbin \"ex\"\n");
        assert!(!out.contains("case key"), "{out}");
        assert!(!out.contains("def initialize"), "{out}");
    }

    #[test]
    fn combines_initialized_fields_without_aliasing_arrays() {
        let out = ruby(
            r#"
            name "ex"
            bin "ex"
            flag "--alpha"
            flag "--beta"
            flag "--quiet" count=#true
            flag "--verbose" count=#true
            flag "--left <value>..."
            flag "--right <value>..."
        "#,
        );
        assert!(out.contains("@alpha = @beta = false"), "{out}");
        assert!(out.contains("@quiet = @verbose = 0"), "{out}");
        assert!(out.contains("@left, @right = [], []"), "{out}");
        assert!(out.contains("parsed.occurrences(key)"), "{out}");
        assert!(out.contains("values.dup"), "{out}");
        assert!(!out.contains(".freeze"), "{out}");
    }

    #[test]
    fn emits_runtime_routing_fields() {
        let out = ruby(
            r#"
            name "busybox"
            bin "busybox"
            multicall #true
            external_subcommand #true
            flag "-v --verbose" count=#true
            flag "--include <value>" var=#true
        "#,
        );
        assert!(out.contains(":external"), "{out}");
        assert!(out.contains("Usage::Parser.rewrite_multicall"), "{out}");
        assert!(out.contains("argv0: nil"), "{out}");
    }

    #[test]
    fn external_results_use_the_resolved_field_name() {
        let out = ruby(
            r#"
            name "ex"
            bin "ex"
            external_subcommand #true
            flag "--external"
        "#,
        );
        assert!(
            out.contains("attr_accessor :external, :external_external"),
            "{out}"
        );
        assert!(
            out.contains(".external_external = parsed.external.dup"),
            "{out}"
        );
    }
}
