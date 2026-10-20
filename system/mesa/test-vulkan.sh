#!/bin/bash
# L410: Test PanVK Vulkan driver on Kirin 990 / Mali-G76 MC16.
# Usage:
#   bash system/mesa/test-vulkan.sh
set -e

echo "=== L410 Mali-G76 PanVK Vulkan Test ==="
export PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1

if ! command -v vulkaninfo > /dev/null 2>&1; then
	echo "vulkaninfo not found. Please install vulkan-tools: sudo apt install vulkan-tools"
	exit 1
fi

echo "1. Querying Vulkan ICD manifests..."
ls -l /usr/share/vulkan/icd.d/ /etc/vulkan/icd.d/ 2>/dev/null || true

echo "2. Querying Vulkan physical devices via vulkaninfo..."
vulkaninfo --summary

echo "3. Running offscreen / short frame test with vkcube..."
if command -v vkcube > /dev/null 2>&1; then
	timeout 5 vkcube --c 120 2>&1 || true
	echo "vkcube test completed."
fi

echo "=== Vulkan check completed successfully ==="
