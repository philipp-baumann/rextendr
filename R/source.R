#' Compile Rust code and call from R
#'
#' [rust_source()] compiles and loads a single Rust file for use in R. [rust_function()]
#' compiles and loads a single Rust function for use in R.
#'
#' @param file Input rust file to source.
#' @param code Input rust code, to be used instead of `file`.
#' @param module_name Name of the module defined in the Rust source via
#'   `extendr_module!`. Default is `"rextendr"`.
#' @param dependencies Character vector of dependencies lines to be added to the
#'   `Cargo.toml` file.
#' @param patch.crates_io Character vector of patch statements for crates.io to
#'   be added to the `Cargo.toml` file.
#' @param profile Rust profile. Can be either `"dev"`, `"release"` or `"perf"`.
#'  The default, `"dev"`, compiles faster but produces slower code.
#' @param toolchain Rust toolchain. The default, `NULL`, compiles with the
#'  system default toolchain. Accepts valid Rust toolchain qualifiers,
#'  such as `"nightly"`, or (on Windows) `"stable-msvc"`.
#' @param extendr_deps Versions of `extendr-*` crates. Defaults to
#'   \code{list(`extendr-api` = "*")}.
#' @param features List of features that control conditional compilation and
#'   optional dependencies.
#' @param env The R environment in which the wrapping functions will be defined.
#' @param use_extendr_api Logical indicating whether
#'   `use extendr_api::prelude::*;` should be added at the top of the Rust source
#'   provided via `code`. Default is `TRUE`. Ignored for Rust source provided
#'   via `file`.
#' @param generate_module_macro Logical indicating whether the Rust module
#'   macro should be automatically generated from the code. Default is `TRUE`.
#'   Ignored for Rust source provided via `file`. The macro generation is done
#'   with [make_module_macro()] and it may fail in complex cases. If something
#'   doesn't work, try calling [make_module_macro()] on your code to see whether
#'   the generated macro code has issues.
#' @param cache_build Logical indicating whether builds should be cached between
#'   calls to [rust_source()].
#' @param quiet Logical indicating whether compile output should be generated or not.
#' @param use_rtools Logical indicating whether to append the path to Rtools
#'   to the `PATH` variable on Windows using the `RTOOLS40_HOME` environment
#'   variable (if it is set). The appended path depends on the process
#'   architecture. Does nothing on other platforms.
#' @return The result from [dyn.load()], which is an object of class `DLLInfo`.
#'  See [getLoadedDLLs()] for more details.
#'
#' @examples
#' \dontrun{
#' # creating a single rust function
#' rust_function("fn add(a:f64, b:f64) -> f64 { a + b }")
#' add(2.5, 4.7)
#'
#' # creating multiple rust functions at once
#' code <- r"(
#' #[extendr]
#' fn hello() -> &'static str {
#'     "Hello, world!"
#' }
#'
#' #[extendr]
#' fn test( a: &str, b: i64) {
#'     rprintln!("Data sent to Rust: {}, {}", a, b);
#' }
#' )"
#'
#' rust_source(code = code)
#' hello()
#' test("a string", 42)
#'
#'
#' # use case with an external dependency: a function that converts
#' # markdown text to html, using the `pulldown_cmark` crate.
#' code <- r"(
#'   use pulldown_cmark::{Parser, Options, html};
#'
#'   #[extendr]
#'   fn md_to_html(input: &str) -> String {
#'     let mut options = Options::empty();
#'     options.insert(Options::ENABLE_TABLES);
#'     let parser = Parser::new_ext(input, options);
#'     let mut output = String::new();
#'     html::push_html(&mut output, parser);
#'     output
#'   }
#' )"
#' rust_source(
#'   code = code,
#'   dependencies = list(`pulldown-cmark` = "0.8")
#' )
#'
#' md_text <- "# The story of the fox
#' The quick brown fox **jumps over** the lazy dog.
#' The quick *brown fox* jumps over the lazy dog."
#'
#' md_to_html(md_text)
#' }
#' @export
rust_source <- function(file, code = NULL,
                        module_name = "rextendr",
                        dependencies = NULL,
                        patch.crates_io = getOption("rextendr.patch.crates_io"),
                        profile = c("dev", "release", "perf"),
                        toolchain = getOption("rextendr.toolchain"),
                        extendr_deps = getOption("rextendr.extendr_deps"),
                        features = NULL,
                        env = parent.frame(),
                        use_extendr_api = TRUE,
                        generate_module_macro = TRUE,
                        cache_build = TRUE,
                        quiet = FALSE,
                        use_rtools = TRUE) {
  profile <- match.arg(profile, several.ok = FALSE)
  if (is.null(extendr_deps)) {
    ui_throw(
      "Invalid argument.",
      bullet_x("`extendr_deps` cannot be `NULL`.")
    )
  }

  dir <- get_build_dir(cache_build)

  if (!isTRUE(quiet)) {
    ui_i("build directory: {.file {dir}}")
  }

  # copy rust code into src/lib.rs and determine library name
  rust_file <- file.path(dir, "src", "lib.rs")
  if (!is.null(code)) {
    if (isTRUE(generate_module_macro)) {
      code <- c(code, make_module_macro(code, module_name))
    }
    if (isTRUE(use_extendr_api)) {
      code <- c("use extendr_api::prelude::*;", code)
    }
    brio::write_lines(code, rust_file)

    # generate lib name
    libname <- paste0("rextendr", the$count)
    the$count <- the$count + 1L
  } else {
    file.copy(file, rust_file, overwrite = TRUE)
    libname <- tools::file_path_sans_ext(basename(file))
  }

  if (!isTRUE(cache_build)) {
    withr::defer(clean_build_dir())
  }

  # generate Cargo.toml file and compile shared library
  cargo.toml_content <- generate_cargo.toml(
    libname = libname,
    dependencies = dependencies,
    patch.crates_io = patch.crates_io,
    extendr_deps = extendr_deps,
    features = features
  )
  brio::write_lines(cargo.toml_content, file.path(dir, "Cargo.toml"))

  # add cargo configuration file to the package
  cargo_config.toml_content <- generate_cargo_config.toml()
  brio::write_lines(cargo_config.toml_content, file.path(dir, ".cargo", "config.toml"))

  # Get target name, not null for Windows
  specific_target <- get_specific_target_name()

  invoke_cargo(
    toolchain = toolchain,
    specific_target = specific_target,
    dir = dir,
    profile = profile,
    quiet = quiet,
    use_rtools = use_rtools
  )

  # load shared library
  libfilename <- paste0(get_dynlib_name(libname), get_dynlib_ext())

  target_folder <- ifelse(
    is.null(specific_target),
    "target",
    sprintf("target%s%s", .Platform$file.sep, specific_target)
  )

  shared_lib <- file.path(
    dir,
    target_folder,
    ifelse(profile == "dev", "debug", profile),
    libfilename
  )

  # Capture loaded dll
  dll_info <- dyn.load(shared_lib, local = TRUE, now = TRUE)

  # generate R bindings for shared library
  wrapper_file <- file.path(dir, "target", "extendr_wrappers.R")


  make_wrappers(
    module_name = as_valid_rust_name(module_name),
    package_name = dll_info[["name"]],
    outfile = wrapper_file,
    use_symbols = FALSE,
    quiet = quiet
  )
  source(wrapper_file, local = env)

  # Invisibly returns to fulfill contract
  invisible(dll_info)
}

#' @rdname rust_source
#' @param ... Other parameters handed off to [rust_source()].
#' @export
rust_function <- function(code, env = parent.frame(), ...) {
  code <- c(
    "#[extendr]",
    stringi::stri_trim(code)
  )

  rust_source(code = code, env = env, ...)
}

#' Sets up environment and invokes Rust's cargo.
#'
#' Configures the environment and makes a call to [system2()],
#'   assuming `cargo` is avaialble on the `PATH`.
#' Function parameters control the formatting of `cargo` arguments.
#'
#' @param toolchain \[string\] Rust toolchain used for compilation.
#' @param specific_target \[string or `NULL`\] Build target (`NULL` if the same as `toolchain`).
#' @param dir \[string\] Path to a folder containing`Cargo.toml` file.
#' @param profile \[string\] Indicates wether to build dev or release versions.
#'   If `"release"`, emits `--release` argument to `cargo`.
#'   Otherwise, does nothing.
#' @param quiet Logical indicating whether compile output should be generated or not.
#' @param use_rtools \[logical, windows_only\] Indicates wether path RTools should be appended to `PATH` variable
#'   for the duration of compilation. Has no effect on systems other than Windows.
#' @noRd
invoke_cargo <- function(toolchain, specific_target, dir, profile,
                         quiet, use_rtools) {
  # Append rtools path to the end of PATH on Windows
  if (
    isTRUE(use_rtools) &&
      .Platform$OS.type == "windows"
  ) {
    if (
      !isTRUE(
        suppressMessages(
          pkgbuild::has_rtools()
        )
      )
    ) {
      ui_throw(
        "Unable to find Rtools that are needed for compilation.",
        details = bullet_i("Required version is {.emph {pkgbuild::rtools_needed()}}.")
      )
    }

    if (identical(R.version$crt, "ucrt")) {
      # TODO: update this when R 5.0 is released.
      if (!identical(R.version$major, "4")) {
        ui_throw("rextendr currently supports R 4.x")
      }

      if (package_version(R.version$minor) >= "3.0") {
        rtools_version <- "43"  # nolint: object_usage_linter
      } else {
        rtools_version <- "42"  # nolint: object_usage_linter
      }

      rtools_home <- normalizePath(
        Sys.getenv(
          glue("RTOOLS{rtools_version}_HOME"),
          glue("C:\\rtools{rtools_version}")
        ),
        mustWork = TRUE
      )

      # c.f. https://github.com/wch/r-source/blob/f09d3d7fa4af446ad59a375d914a0daf3ffc4372/src/library/profile/Rprofile.windows#L70-L71 # nolint: line_length_linter
      subdir <- c("x86_64-w64-mingw32.static.posix", "usr")
    } else {
      # rtools_path() returns path to the RTOOLS40_HOME\usr\bin,
      # but we need RTOOLS40_HOME\mingw{arch}\bin, hence the "../.."
      rtools_home <- normalizePath(
        # `pkgbuild` may return two paths for R < 4.2 with Rtools40v2
        file.path(pkgbuild::rtools_path()[1], "..", ".."),
        winslash = "/",
        mustWork = TRUE
      )

      subdir <- paste0("mingw", ifelse(R.version$arch == "i386", "32", "64"))
      # If RTOOLS40_HOME is properly set, this will have no real effect
      withr::local_envvar(RTOOLS40_HOME = rtools_home)
    }

    rtools_bin_path <- normalizePath(file.path(rtools_home, subdir, "bin"))
    withr::local_path(rtools_bin_path, action = "suffix")
  }

  message_buffer <- character(0)
  env <- rlang::current_env()
  cargo_envvars <- get_cargo_envvars()

  compilation_result <- processx::run(
    command = "cargo",
    args = c(
      glue("+{toolchain}"),
      "build",
      "--lib",
      glue("--target={specific_target}"),
      glue("--manifest-path={file.path(dir, 'Cargo.toml')}"),
      glue("--target-dir={file.path(dir, 'target')}"),
      glue("--profile={profile}"),
      "--message-format=json-diagnostic-rendered-ansi",
      if (tty_has_colors()) {
        "--color=always"
      } else {
        "--color=never"
      }
    ),
    echo_cmd = FALSE,
    windows_verbatim_args = FALSE,
    stderr = if (isTRUE(quiet)) "|" else "",
    stdout = "|",
    error_on_status = FALSE,
    stdout_line_callback = function(line, ...) {
      assign("message_buffer", c(message_buffer, line), envir = env)
    },
    env = cargo_envvars
  )

  check_cargo_output(compilation_result, message_buffer, tty_has_colors(), quiet)
}

#' Gathers ANSI-formatted cargo output
#'
#' Checks the output of cargo and filters messages according to `level`.
#' Retrieves rendered ANSI strings and prepares them
#' for `cli` and `glue` formatting.
#' @param json_output \[ JSON(n) \] JSON messages produced by cargo.
#' @param level \[ string \] Log level.
#' Commonly used values are `"error"` and `"warning"`.
#' @param tty_has_colors \[ logical(1) \] Indicates if output
#' supports ANSI sequences. If `FALSE`, ANSI sequences are stripped off.
#' @return \[ character(n) \] Vector of strings
#' that can be passed to `ui_*`, `cli` or `glue` functions.
#' @noRd
gather_cargo_output <- function(json_output, level, tty_has_colors) {
  rendered_output <-
    json_output %>%
    purrr::keep(
      ~ .x$reason == "compiler-message" && .x$message$level == level
    ) %>%
    purrr::map_chr(~ .x$message$rendered)

  if (!tty_has_colors) {
    rendered_output <- cli::ansi_strip(rendered_output)
  }

  stringi::stri_replace_all_fixed(
    rendered_output,
    pattern = c("{", "}"),
    replacement = c("{{", "}}"),
    vectorize_all = FALSE
  )
}

#' Processes output of cargo compilation process.
#'
#' Displays warnings emitted by the compiler
#' and throws errors if compilation was unsuccessful.
#' @param compilation_result The output of `processx::run()`.
#' @param message_buffer \[ character(n) \] Messages emitted by cargo to stdout.
#' @param tty_has_colors \[ logical(1) \] Indicates if output
#' supports ANSI sequences. If `FALSE`, ANSI sequences are stripped off.
#' @param quiet Logical indicating whether compile output should be generated or not.
#' @param call Caller environment used for error message formatting.
#' @noRd
check_cargo_output <- function(compilation_result, message_buffer, tty_has_colors, quiet, call = caller_env()) {
  cargo_output <- purrr::map(
    message_buffer,
    jsonlite::parse_json
  )

  if (!isTRUE(quiet)) {
    purrr::walk(
      gather_cargo_output(
        cargo_output,
        "warning",
        tty_has_colors
      ),
      ui_w
    )
  }

  if (!isTRUE(compilation_result$status == 0)) {
    error_messages <- purrr::map_chr(
      gather_cargo_output(
        cargo_output,
        "error",
        tty_has_colors
      ),
      bullet_x
    )

    ui_throw(
      "Rust code could not be compiled successfully. Aborting.",
      error_messages,
      call = call,
      glue_open = "{<{",
      glue_close = "}>}"
    )
  }
}

generate_cargo.toml <- function(libname = "rextendr",
                                dependencies = NULL,
                                patch.crates_io = NULL,
                                extendr_deps = NULL,
                                features = NULL) {
  to_toml(
    package = list(
      name = libname,
      version = "0.0.1",
      edition = "2021",
      resolver = "2"
    ),
    lib = list(
      `crate-type` = array("cdylib", 1)
    ),
    dependencies = append(
      extendr_deps,
      dependencies
    ),
    `patch.crates-io` = patch.crates_io,
    features = features,
    `profile.perf` = list(
      inherits = "release",
      lto = "thin",
      `opt-level` = 3,
      panic = "abort",
      `codegen-units` = 1
    )
  )
}

generate_cargo_config.toml <- function() {
  to_toml(
    build = list(
      rustflags = c("-C", "target-cpu=native"),
      `target-dir` = "target"
    )
  )
}

get_dynlib_ext <- function() {
  # .Platform$dynlib.ext is not reliable on OS X, so need to work around it
  sysinf <- Sys.info()
  if (!is.null(sysinf)) {
    os <- sysinf["sysname"]
    if (os == "Darwin") {
      return(".dylib")
    }
  }
  .Platform$dynlib.ext
}

get_dynlib_name <- function(libname) {
  if (.Platform$OS.type == "windows") {
    libname
  } else {
    paste0("lib", libname)
  }
}

get_specific_target_name <- function() {
  sysinf <- Sys.info()

  if (!is.null(sysinf) && sysinf["sysname"] == "Windows") {
    if (R.version$arch == "x86_64") {
      return("x86_64-pc-windows-gnu")
    }

    if (R.version$arch == "i386") {
      return("i686-pc-windows-gnu")
    }

    ui_throw("Unknown Windows architecture")
  }

  return(NULL)
}

the <- new.env(parent = emptyenv())
the$build_dir <- NULL
the$count <- 1L

get_build_dir <- function(cache_build) {
  if (!isTRUE(cache_build)) {
    clean_build_dir()
  }

  if (is.null(the$build_dir)) {
    dir <- tempfile()
    dir.create(dir)
    dir.create(file.path(dir, "R"))
    dir.create(file.path(dir, "src"))
    dir.create(file.path(dir, ".cargo"))
    the$build_dir <- normalizePath(dir, winslash = "/")
  }
  the$build_dir
}

clean_build_dir <- function() {
  if (!is.null(the$build_dir)) {
    unlink(the$build_dir, recursive = TRUE)
    the$build_dir <- NULL
  }
}
