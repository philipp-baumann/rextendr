#' Set up a package for use with Rust extendr code
#'
#' Create the scaffolding needed to add Rust extendr code to an R package. `use_extendr()`
#' adds a small Rust library with a single Rust function that returns the string
#' `"Hello world!"`. It also adds wrapper code so this Rust function can be called from
#' R with `hello_world()`.
#'
#' To avoid possibly messing up your R package, `use_extendr()` will not do anything if
#' either a directory `src` or a file `R/extendr-wrappers.R` is already present in your
#' package source.
#'
#' @param path File path to the package for which to generate wrapper code.
#' @param crate_name String that is used as the name of the Rust crate.
#' If `NULL`, sanitized R package name is used instead.
#' @param lib_name String that is used as the name of the Rust library.
#' If `NULL`, sanitized R package name is used instead.
#' @param quiet Logical indicating whether any progress messages should be
#'   generated or not. Also checks the `usethis.quiet` option.
#' @param edition String indicating which Rust edition is used; Default `"2021"`.
#' @return A logical value (invisible) indicating whether any package files were
#' generated or not.
#' @export
use_extendr <- function(path = ".",
                        crate_name = NULL,
                        lib_name = NULL,
                        quiet = getOption("usethis.quiet", FALSE),
                        edition = c("2021", "2018")) {
  usethis_quiet <- getOption("usethis.quiet")
  on.exit(options(usethis.quiet = usethis_quiet))
  options(usethis.quiet = quiet)

  rextendr_setup(path = path)

  pkg_name <- pkg_name(path)
  mod_name <- as_valid_rust_name(pkg_name)

  if (is.null(crate_name)) {
    crate_name <- mod_name
  } else {
    throw_if_invalid_rust_name(crate_name)
  }

  if (is.null(lib_name)) {
    lib_name <- mod_name
  } else {
    throw_if_invalid_rust_name(lib_name)
  }

  src_dir <- rprojroot::find_package_root_file("src", path = path)
  r_dir <- rprojroot::find_package_root_file("R", path = path)
  wrappers_file <- rprojroot::find_package_root_file("R", "extendr-wrappers.R", path = path)
  if (!dir.exists(r_dir)) {
    ui_v("Writing {.file R/}")
    dir.create(r_dir)
  }

  if (dir.exists(src_dir)) {
    ui_x("Directory {.file src} already present in package source. No action taken.")
    return(invisible(FALSE))
  }
  if (file.exists(wrappers_file)) {
    ui_x("File {.file R/extendr-wrappers.R} already present in package source. No action taken.")
    return(invisible(FALSE))
  }

  rust_src_dir <- file.path(src_dir, "rust", "src")
  dir.create(rust_src_dir, recursive = TRUE)
  ui_v("Creating {.file {pretty_rel_path(rust_src_dir, path)}}.")

  use_rextendr_template(
    "entrypoint.c",
    save_as = file.path("src", "entrypoint.c"),
    quiet = quiet,
    data = list(mod_name = mod_name)
  )

  use_rextendr_template(
    "Makevars",
    save_as = file.path("src", "Makevars"),
    quiet = quiet,
    data = list(lib_name = lib_name)
  )

  use_rextendr_template(
    "Makevars.win",
    save_as = file.path("src", "Makevars.win"),
    quiet = quiet,
    data = list(lib_name = lib_name)
  )

  use_rextendr_template(
    "Makevars.ucrt",
    save_as = file.path("src", "Makevars.ucrt"),
    quiet = quiet,
    data = list(lib_name = lib_name)
  )

  use_rextendr_template(
    "_gitignore",
    save_as = file.path("src", ".gitignore"),
    quiet = quiet
  )

  edition <- match.arg(edition, several.ok = FALSE)
  cargo_toml_content <- to_toml(
    package = list(name = crate_name, version = "0.1.0", edition = edition),
    lib = list(`crate-type` = array("staticlib", 1), name = lib_name),
    dependencies = list(`extendr-api` = "*")
  )

  write_file(
    text = cargo_toml_content,
    path = file.path("src", "rust", "Cargo.toml"),
    search_root_from = path,
    quiet = quiet
  )

  use_rextendr_template(
    "lib.rs",
    save_as = file.path("src", "rust", "src", "lib.rs"),
    quiet = quiet,
    data = list(mod_name = mod_name)
  )

  use_rextendr_template(
    "win.def",
    save_as = file.path("src", paste0(pkg_name, "-win.def")),
    quiet = quiet,
    data = list(mod_name = mod_name)
  )

  use_rextendr_template(
    "extendr-wrappers.R",
    save_as = file.path("R", "extendr-wrappers.R"),
    quiet = quiet,
    data = list(pkg_name = pkg_name)
  )

  if (!isTRUE(quiet)) {
    ui_v("Finished configuring {.pkg extendr} for package {.pkg {pkg_name}}.")
    ui_o("Please update the system requirement in {.file DESCRIPTION} file.")
    ui_o("Please run {.fun rextendr::document} for changes to take effect.")
  }

  return(invisible(TRUE))
}

#' Checks if provided name is a valid Rust name (identifier)
#'
#' @param name \[ character(n) \] Names to test.
#' @return \[ logical(n) \] `TRUE` if the name is valid, otherwise `FALSE`.
#' @noRd
is_valid_rust_name <- function(name) {
  # We require the name starts with a letter,
  # ends with a letter or digit,
  # and contains only alphanumeric ASCII chars, `-` or `_`.
  stringi::stri_detect_regex(name, "^[A-z][\\A-z0-9_-]*[A-z0-9]$")
}

#' Convert R package name into equivalent valid Rust name.
#'
#' @param r_name \[ character(n) \] R names to convert.
#' @return \[ character(n) \] Equivalent Rust name (if exists), otherwise `NA`.
#' @noRd
as_valid_rust_name <- function(r_name) {
  rust_name <- stringi::stri_replace_all_fixed(r_name, ".", "_")
  throw_if_invalid_rust_name(rust_name)
  rust_name
}

#' Verifies if a function argument is a valid Rust name.
#'
#' @param name \[ string \] Tested caller function argument.
#' @param call \[ env \] Environment of the caller, passed to `ui_throw()`.
#' @noRd
throw_if_invalid_rust_name <- function(name, call = caller_env()) {
  quo <- enquo(name) # nolint: object_usage_linter
  if (!rlang::is_scalar_character(name) || !is_valid_rust_name(name)) {
    ui_throw(
      "Argument {.arg {as_name(quo)}} is invalid.",
      bullet_w("{.code {as_label(name)}} cannot be used as Rust package or library name."),
      call = call
    )
  }
}
#' Write templates from `inst/templates`
#'
#' `use_rextendr_template()` is a wrapper around `usethis::use_template()` when
#' it's available and otherwise implements a simple version of `use_template()`.
#'
#' @inheritParams usethis::use_template
#' @inheritParams use_extendr
#'
#' @noRd
use_rextendr_template <- function(template,
                                  save_as = template,
                                  data = list(),
                                  quiet = getOption("usethis.quiet", FALSE)) {
  if (is_installed("usethis")) {
    withr::local_options(usethis.quiet = quiet)
    created <- usethis::use_template(
      template,
      save_as = save_as,
      data = data,
      open = FALSE,
      package = "rextendr"
    )

    return(invisible(created))
  }

  template_path <- system.file(
    "templates",
    template,
    package = "rextendr",
    mustWork = TRUE
  )

  template_content <- brio::read_file(template_path)

  template_content <- glue::glue_data(
    template_content,
    .x = data,
    .open = "{{{", .close = "}}}",
    .trim = FALSE
  )

  write_file(
    stringi::stri_trim(template_content),
    path = save_as,
    search_root_from = rprojroot::find_package_root_file(),
    quiet = quiet
  )

  invisible(TRUE)
}

# Wrap `rlang::is_installed()` for ease of mocking installed packages
is_installed <- function(pkg) {
  rlang::is_installed(pkg)
}

pkg_name <- function(path = ".") {
  x <- desc::desc(rprojroot::find_package_root_file("DESCRIPTION", path = path))
  x$get("Package")
}
