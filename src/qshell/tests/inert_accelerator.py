"""Retain the generated accelerator ports for a protocol-only wrapper test.

Zero-operation jobs require no accelerator transaction. Reject any attempted
transaction rather than emulating or claiming decoder correctness.
"""
import re
import sys

lines = []
with open(sys.argv[1]) as source:
    for line in source:
        if lines or re.match(r"module MicroBlossomBus\s*\(", line):
            lines.append(line)
            if line.strip() == ");":
                break
    else:
        raise ValueError("Missing generated accelerator port declaration")
print("".join(lines))
for line in lines:
    match = re.match(r"\s*output\s+.*?\b(\w+)\s*,?\s*$", line)
    if match:
        print(f"assign {match[1]} = '0;")
print('always_comb if (s0_awvalid || s0_arvalid) $fatal(1, "Unexpected accelerator transaction");')
print("endmodule")
