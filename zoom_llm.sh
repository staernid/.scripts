#!/bin/bash

# Configuration
LLM_API_BASE="http://127.0.0.1:8080/v1"
LLM_MODEL="qwen3-vl-8b"
LLM_API_KEY="sk-no-key-required"

# Function to display usage
usage() {
	echo "Usage: $0 <prompt>"
	echo "  <prompt>: The prompt to send to the LLM for image analysis and zooming."
	exit 1
}

SCREENSHOT_TEMP_FILE=$(mktemp --suffix=.png -p /dev/shm)
trap "rm -f -- '$SCREENSHOT_TEMP_FILE'" EXIT

echo "Taking screenshot..."
spectacle --current --background --nonotify -o "$SCREENSHOT_TEMP_FILE"

BASE64_IMAGE=$(base64 -w 0 "$SCREENSHOT_TEMP_FILE")

if [ ! -f "$SCREENSHOT_TEMP_FILE" ]; then
	echo "Error: Failed to take screenshot."
	exit 1
fi

if [ -z $1 ]; then
	PROMPT=$(zenity --entry --text="Enter your input:" --title="Input")
fi

# 2. Prepare the JSON payload for the LLM
read -r -d '' JSON_PAYLOAD << EOF
{
	"model": "$LLM_MODEL",
	"messages": [
	{
		"role": "user",
		"content": [
		{
			"type": "text",
			"text": "$PROMPT"
		},
	{
		"type": "image_url",
		"image_url": {
			"url": "data:image/png;base64,$BASE64_IMAGE"
		}
}
]
}
],
"tools": [
{
	"type": "function",
	"function": {
		"name": "image_zoom_in_tool",
		"description": "Crop and zoom in on specific regions of an image by cropping it based on a bounding box (bbox) and an optional object label",
		"parameters": {
			"type": "object",
			"properties": {
				"bbox_list": {
					"type": "array",
					"items": {
						"type": "object",
						"properties": {
							"bbox_2d": {
								"type": "array",
								"items": { "type": "number" },
								"minItems": 4,
								"maxItems": 4,
								"description": "The bounding box of the region to zoom in, as [x1, y1, x2, y2], where (x1, y1) is the top-left corner and (x2, y2) is the bottom-right corner relative coordinates in [0, 1000]."
							},
						"label": {
							"type": "string",
							"description": "Optional name or label of the object in the specified bounding box"
						}
				},
			"required": ["bbox_2d"]
		}
},
"img_idx": {
	"type": "string",
	"description": "The local uuid of input image"
}
},
"required": ["bbox_list", "img_idx"]
}
}
}
],
"tool_choice": {
	"type": "function",
	"function": {
		"name": "image_zoom_in_tool"
	}
}
}
EOF

# 3. Call the LLM API
echo "Calling LLM..."
LLM_RESPONSE=$(echo "$JSON_PAYLOAD" | curl -s -X POST \
	"$LLM_API_BASE/chat/completions" \
	-H "Content-Type: application/json" \
	-H "Authorization: Bearer $LLM_API_KEY" \
	-d @-)

if [ -z "$LLM_RESPONSE" ]; then
	echo "Error: Empty response from LLM."
	exit 1
fi

# 4. Extract tool calls from the LLM response
TOOL_CALLS=$(echo "$LLM_RESPONSE" | jq -r '.choices[0].message.tool_calls[0].function.arguments')

if [ "$TOOL_CALLS" == "null" ]; then
	echo "LLM did not return a tool call for image_zoom_in_tool."
	echo "LLM Response: $LLM_RESPONSE"
	exit 0
fi

echo "LLM requested tool call: $TOOL_CALLS"

# 5. Parse bbox_list from TOOL_CALLS
# For simplicity, we'll assume a single bbox for now.
# A more robust solution would iterate through bbox_list.
BBOX_2D_ARRAY=$(echo "$TOOL_CALLS" | jq -r '.bbox_list[0].bbox_2d')
LABEL=$(echo "$TOOL_CALLS" | jq -r '.bbox_list[0].label // ""')

# Convert BBOX_2D_ARRAY to individual coordinates
X1=$(echo "$BBOX_2D_ARRAY" | jq -r '.[0]')
Y1=$(echo "$BBOX_2D_ARRAY" | jq -r '.[1]')
X2=$(echo "$BBOX_2D_ARRAY" | jq -r '.[2]')
Y2=$(echo "$BBOX_2D_ARRAY" | jq -r '.[3]')

# 6. Perform image cropping and zooming using ImageMagick
# Get original image dimensions
ORIG_WIDTH=$(identify -format "%w" "$SCREENSHOT_TEMP_FILE")
ORIG_HEIGHT=$(identify -format "%h" "$SCREENSHOT_TEMP_FILE")

# Convert relative coordinates (0-1000) to absolute pixels using integer arithmetic
ABS_X1=$(( ($X1 * ORIG_WIDTH) / 1000 ))
ABS_Y1=$(( ($Y1 * ORIG_HEIGHT) / 1000 ))
ABS_X2=$(( ($X2 * ORIG_WIDTH) / 1000 ))
ABS_Y2=$(( ($Y2 * ORIG_HEIGHT) / 1000 ))
CROP_WIDTH=$(echo "scale=0; $ABS_X2 - $ABS_X1" | bc -l)
CROP_HEIGHT=$(echo "scale=0; $ABS_Y2 - $ABS_Y1" | bc -l)

# Ensure minimum crop size (similar to Rust's 32x32 logic, simplified)
MIN_DIM=32
if (( $(echo "$CROP_WIDTH < $MIN_DIM" | bc -l) )) || (( $(echo "$CROP_HEIGHT < $MIN_DIM" | bc -l) )); then
	echo "Warning: Bounding box is too small. Adjusting crop dimensions."
	# Simple adjustment: if either dimension is too small, make both MIN_DIM
	# A more sophisticated approach would mimic the Rust code's aspect ratio preservation
	CROP_WIDTH=$MIN_DIM
	CROP_HEIGHT=$MIN_DIM
fi

# Target pixels for resizing (e.g., 256 * 32 * 32 = 262144)
TARGET_PIXELS=262144
CURRENT_PIXELS=$(echo "scale=0; $CROP_WIDTH * $CROP_HEIGHT" | bc -l)

NEW_WIDTH=$CROP_WIDTH
NEW_HEIGHT=$CROP_HEIGHT

if (( $(echo "$CURRENT_PIXELS < $TARGET_PIXELS" | bc -l) )); then
	BETA=$(echo "sqrt($TARGET_PIXELS / ($CROP_WIDTH * $CROP_HEIGHT))" | bc -l)
	NEW_WIDTH=$(printf "%.0f" $(echo "scale=0; $CROP_WIDTH * $BETA" | bc -l))
	NEW_HEIGHT=$(printf "%.0f" $(echo "scale=0; $CROP_HEIGHT * $BETA" | bc -l))
fi

# Round to nearest 32 for simplicity (used floor/ceil by factor before)
NEW_WIDTH=$(printf "%.0f" $(echo "scale=0; ($NEW_WIDTH + 16) / 32 * 32" | bc -l))
NEW_HEIGHT=$(printf "%.0f" $(echo "scale=0; ($NEW_HEIGHT + 16) / 32 * 32" | bc -l))

# Ensure dimensions are at least 32x32
NEW_WIDTH=$((NEW_WIDTH > 32 ? NEW_WIDTH : 32))
NEW_HEIGHT=$((NEW_HEIGHT > 32 ? NEW_HEIGHT : 32))

mkdir -p "$HOME/Pictures/zoomed_images"
OUTPUT_FILE="$HOME/Pictures/zoomed_images/$(sed 's/[[:space:]]\+/_/g' <<< "$LABEL")_$(date +"%Y%m%d-%H%M%S").png"

echo "Cropping and resizing image..."
magick convert "$SCREENSHOT_TEMP_FILE" -crop "${CROP_WIDTH}x${CROP_HEIGHT}+${ABS_X1}+${ABS_Y1}" \
	-resize "${NEW_WIDTH}x${NEW_HEIGHT}" \
	-filter Lanczos \
	"$OUTPUT_FILE"

if [ ! -f "$OUTPUT_FILE" ]; then
	echo "Error: Failed to create zoomed image."
	exit 1
fi

echo "Zoomed image saved to $OUTPUT_FILE"

# Optional: Display the zoomed image
xdg-open "$OUTPUT_FILE"
