#!/usr/bin/env python3
"""
Error log analyzer for kernel build
Original shell author: JackA1ltman <cs2dtzq@163.com>
Python version
"""

import re
import sys
from pathlib import Path
from typing import List, Tuple


def print_separator():
    """Print separator line"""
    print("-" * 56)


def analyze_error_block(error_lines: List[str]) -> Tuple[str, str]:
    """
    Analyze error block and return error type and suggestion
    """
    error_block_text = "\n".join(error_lines)
    error_type = "Uncommon Error"
    suggestion = "Please follow the compilation output error results and try to resolve using search engines"

    # Define error patterns and their corresponding types and suggestions
    error_patterns = [
        (
            r"No such file or directory",
            "Missing Header or Source File",
            "Check if the file path is correct, or if required development libraries are missing (e.g., libssl-dev, zlib1g-dev)."
        ),
        (
            r"undefined reference to",
            "Link Error: Missing Library or Function",
            "Check if required libraries are missing (e.g., -lssl, -lcrypto), if library paths are in LDFLAGS/LDLIBS, or if function names are misspelled."
        ),
        (
            r"unrecognized command line option",
            "Compiler Option Not Supported",
            "Your compiler version may be too old or too new. Check the options passed to the compiler in the Makefile for compatibility with your compiler version. Consider upgrading or downgrading the toolchain."
        ),
        (
            r"misleading-indentation",
            "Code Indentation Does Not Match Logic",
            "This is a code style/logic potential error. Add braces '{}' after 'if', 'for', 'while' statements to clarify code block scope. Or disable this warning (not recommended)."
        ),
        (
            r"type specifier missing",
            "C Language Type Declaration Missing",
            "Variable or function declarations may be missing types (e.g., 'int'). For kernel modules, it could be missing headers or ordering issues, or API changes between kernel versions."
        ),
        (
            r"make\[\d+\]:.*Error \d+",
            "Makefile Build Error",
            "This is a Makefile rule execution failure. Check the specific error messages above, usually a subcommand (e.g., 'gcc', 'ld', 'sh') returned a non-zero status code."
        ),
        (
            r"target emulation unknown",
            "Linker Emulation Mode Error",
            "Your linker (ld) does not recognize the specific emulation mode. Check if LLVM and GNU toolchains are mixed, or ensure LD variable correctly points to LLVM's lld."
        ),
        (
            r"cannot open.*\.gz",
            "File Missing (Configuration May Not Be Generated)",
            "Check if 'make defconfig' or your device-specific config has been run. If 'make mrproper' was executed previously, reconfiguration is needed."
        ),
        (
            r"makes pointer from integer without a cast",
            "Type Conversion Error (Pointer and Integer)",
            "This is a severe type mismatch. Usually the function return type does not match the expected type (e.g., returning int but expecting pointer). May need to modify source code or use a more compatible compiler."
        ),
        (
            r"MODULE_IMPORT_NS\(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver\)",
            "Clang Version Anomaly",
            "This is a compiler and KernelSU compatibility issue, usually occurs with KernelSU official version and SukiSU-Ultra. For official version, you can choose the old v0.9.5 version; for SukiSU-Ultra, it is generally recommended to switch to a different KernelSU branch."
        ),
        (
            r"not found \(required by clang\)",
            "Clang Version Anomaly",
            "The current build system version is too old. If using 20.04, please use 22.04, otherwise use latest."
        ),
        (
            r"multiple definition of 'yylloc'",
            "Kernel Defect",
            "Modify YYLTYPE yylloc to extern YYLTYPE yylloc in scripts/dtc/dtc-lexer.lex.c_shipped"
        ),
        (
            r"assembler command failed with exit code 1",
            "Clang Compiler Error",
            "Switch to a different Clang compiler version"
        ),
        (
            r"incompatible pointer types passing 'atomic_long_t \*'",
            "Source Code Pointer Type Error",
            "Usually occurs after manual patching of cred.h, replace atomic_inc_not_zero with atomic_long_inc_not_zero in the code"
        ),
        (
            r"-Werror",
            "Warning Treated as Error",
            "The compiler is treating warnings as errors due to -Werror flag. Either fix the underlying warning, or temporarily remove -Werror from CFLAGS/KBUILD_CFLAGS in the Makefile to allow compilation with warnings."
        ),
        (
            r"implicit declaration of function",
            "Implicit Function Declaration",
            "A function is being used without being declared first. Include the proper header file, or add a function declaration/prototype before use. This may also indicate an API change in newer kernel versions."
        ),
        (
            r"array subscript.*is outside array bounds",
            "Array Index Out of Bounds",
            "Accessing an array element outside its declared size. Check array bounds and ensure indices are within valid range [0, size-1]. This could be a buffer overflow risk."
        ),
        (
            r"division by zero",
            "Division by Zero",
            "Code attempts to divide by zero. Add proper checks to ensure the divisor is not zero before performing division operations."
        ),
        (
            r"null pointer dereference",
            "Null Pointer Dereference",
            "Attempting to access memory through a null pointer. Add null checks before dereferencing pointers, or ensure proper initialization before use."
        ),
        (
            r"incompatible implicit declaration",
            "Incompatible Implicit Declaration",
            "Function was implicitly declared with a signature that doesn't match its actual definition. Include the correct header or add a proper function prototype."
        ),
        (
            r"unused variable",
            "Unused Variable",
            "A variable is declared but never used. Either use the variable, remove it, or mark it with __maybe_unused attribute to suppress the warning."
        ),
        (
            r"uninitialized variable",
            "Uninitialized Variable",
            "A variable is being used before being initialized. Initialize the variable at declaration or before first use."
        ),
        (
            r"dereferencing pointer to incomplete type",
            "Dereferencing Incomplete Type",
            "Attempting to access members of a struct/union that hasn't been fully defined. Include the header file containing the complete type definition."
        ),
        (
            r"conflicting types",
            "Conflicting Types",
            "A function or variable has been declared with different types in different places. Ensure all declarations match the definition exactly."
        ),
        (
            r"redefinition of ",
            "Symbol Redefinition",
            "A function, variable, or macro has been defined multiple times. Check for duplicate definitions or include guards in header files."
        ),
        (
            r"deprecated",
            "Deprecated API Usage",
            "Using a deprecated function or feature. Update the code to use the recommended replacement API or suppress with -Wno-deprecated-declarations (not recommended for long-term)."
        ),
        (
            r"overflow in conversion",
            "Integer Overflow in Conversion",
            "A value is being converted to a type that cannot hold it. Check value ranges and use appropriate data types or add bounds checking."
        ),
        (
            r"shift count overflow",
            "Bit Shift Overflow",
            "The shift amount exceeds the bit width of the type. Ensure shift counts are less than the type's bit width (e.g., < 32 for int32)."
        ),
        (
            r"cast from pointer to integer of different size",
            "Pointer to Integer Size Mismatch",
            "Converting a pointer to an integer type with different size. Use uintptr_t or intptr_t types which are guaranteed to hold pointer values."
        ),
        (
            r"variable length array",
            "Variable Length Array (VLA) Used",
            "Using VLA which may cause stack overflow. Consider using dynamic allocation (kmalloc/vmalloc for kernel) instead, or ensure size is bounded."
        ),
        (
            r"taking address of temporary",
            "Address of Temporary Value",
            "Attempting to take the address of a temporary/rvalue. Store the value in a variable first, then take its address."
        ),
        (
            r"control reaches end of non-void function",
            "Missing Return Statement",
            "A non-void function may reach the end without returning a value. Add a return statement at the end of all code paths."
        ),
        (
            r"comparison of integer expressions of different signedness",
            "Signed/Unsigned Comparison",
            "Comparing signed and unsigned integers. Cast one operand to match the other's type, or ensure consistent types throughout."
        ),
        (
            r"result of operation is still indeterminate",
            "Sequence Point Violation",
            "Undefined behavior due to multiple modifications between sequence points. Break the expression into multiple statements."
        ),
        (
            r"stack-protector",
            "Stack Protection Enabled But Failed",
            "Stack smashing detected or stack protector instrumentation failed. Check for buffer overflows in the code, or disable with -fno-stack-protector (not recommended)."
        ),
        (
            r"clock skew detected",
            "Clock Skew Detected",
            "File timestamps are in the future. Synchronize system clock or touch the affected files to update timestamps."
        ),
    ]

    for pattern, etype, sugg in error_patterns:
        if re.search(pattern, error_block_text, re.IGNORECASE):
            error_type = etype
            suggestion = f"Suggestion: {sugg}"
            break

    return error_type, suggestion


def analyze_errors(log_file: str) -> int:
    """
    Analyze error log file and print analysis results
    Returns: number of errors found
    """
    log_path = Path(log_file)
    if not log_path.exists():
        print(f"::warning:: Log file '{log_file}' does not exist.")
        print("Skipping error analysis because no build output was recorded. "
              "Ensure the kernel build step progressed far enough to generate a log.")
        return 0

    print(f"Analyzing log file: {log_file}")
    print_separator()

    error_count = 0
    current_error_lines: List[str] = []
    processing_error = False
    error_blocks: List[List[str]] = []

    with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.rstrip('\n\r')

            # Check for error start
            if re.search(r'\serror:|\sfatal error:|undefined reference to', line, re.IGNORECASE):
                # Save previous error block if exists
                if processing_error and current_error_lines:
                    error_blocks.append(current_error_lines.copy())

                processing_error = True
                error_count += 1
                current_error_lines = [line]
            # Check for continuation lines (notes, make errors)
            elif processing_error and (
                'note:' in line or
                (re.search(r'make\[\d+\]:', line) and '***' in line) or
                line.strip()
            ):
                current_error_lines.append(line)
            else:
                # Error block ended
                if processing_error and current_error_lines:
                    error_blocks.append(current_error_lines.copy())
                processing_error = False
                current_error_lines = []

    # Handle last error block
    if processing_error and current_error_lines:
        error_blocks.append(current_error_lines)

    # Collect error summaries for final summary
    error_summaries: List[Tuple[str, str]] = []

    # Process and display each error block
    for idx, block in enumerate(error_blocks, 1):
        print(f"Error #{idx}:")
        for error_line in block:
            print(f"  {error_line}")

        error_type, suggestion = analyze_error_block(block)
        print(f"Error: {error_type}")
        print(f"Suggestion: {suggestion}")
        print_separator()

        # Store for summary
        error_summaries.append((error_type, suggestion))

    # Summary
    if error_count > 0:
        print(f"Total found {error_count} error(s).")
        print("Please carefully review the error messages and suggestions above.")
        # Create have_error marker file
        Path('have_error').touch()
    else:
        print("No errors found.")

    print_separator()

    # Print final summary at the bottom for CI visibility
    if error_count > 0:
        print("\n")
        print("=" * 56)
        print("                    Error Summary")
        print("=" * 56)
        for idx, (etype, sugg) in enumerate(error_summaries, 1):
            print(f"\n  [{idx}] {etype}")
            print(f"      {sugg}")
        print("\n" + "=" * 56)
        print(f"Total: {error_count} error(s)")
        print("=" * 56)

    return error_count


def main():
    """Main function"""
    log_file = sys.argv[1] if len(sys.argv) > 1 else 'error.log'
    analyze_errors(log_file)


if __name__ == '__main__':
    main()
