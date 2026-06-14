package usagesync

import (
	"encoding/json"
	"testing"
)

func TestTransformRecord_withUsage(t *testing.T) {
	input := `{"timestamp":"2024-01-01T00:00:00Z","cwd":"/home/dev/oldpath","requestId":"req123","costUSD":0.05,"isApiErrorMessage":false,"message":{"id":"msg1","model":"claude-3-5-sonnet","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10,"cache_creation_input_tokens":5,"cache_creation":null},"content":"should be dropped","role":"assistant"}}`

	out, ok := transformRecord([]byte(input), "/home/dev/myproject")
	if !ok {
		t.Fatal("transformRecord returned ok=false, expected ok=true")
	}

	var rec map[string]interface{}
	if err := json.Unmarshal(out, &rec); err != nil {
		t.Fatalf("output is not valid JSON: %v\nOutput: %s", err, out)
	}

	// Required fields must be present
	if rec["timestamp"] == nil {
		t.Error("timestamp missing")
	}
	if rec["requestId"] == nil {
		t.Error("requestId missing")
	}

	// cwd must be rewritten to the new value
	if rec["cwd"] != "/home/dev/myproject" {
		t.Errorf("cwd = %v, want /home/dev/myproject", rec["cwd"])
	}

	// message must be present
	msg, ok2 := rec["message"].(map[string]interface{})
	if !ok2 {
		t.Fatalf("message missing or not object: %v", rec["message"])
	}
	if msg["id"] == nil {
		t.Error("message.id missing")
	}
	if msg["model"] == nil {
		t.Error("message.model missing")
	}

	// usage must be present and stripped to allowed fields only
	usage, ok3 := msg["usage"].(map[string]interface{})
	if !ok3 {
		t.Fatalf("message.usage missing or not object: %v", msg["usage"])
	}
	if usage["input_tokens"] == nil {
		t.Error("message.usage.input_tokens missing")
	}
	if usage["output_tokens"] == nil {
		t.Error("message.usage.output_tokens missing")
	}

	// Disallowed fields must NOT be present
	if _, found := msg["content"]; found {
		t.Error("message.content must be dropped")
	}
	if _, found := msg["role"]; found {
		t.Error("message.role must be dropped")
	}
	if _, found := rec["extra"]; found {
		t.Error("extra fields must be dropped")
	}
}

func TestTransformRecord_withoutUsage(t *testing.T) {
	input := `{"timestamp":"2024-01-01T00:00:00Z","message":{"id":"msg1","model":"claude-3-5-sonnet"}}`
	_, ok := transformRecord([]byte(input), "/home/dev/proj")
	if ok {
		t.Error("expected ok=false for record without message.usage")
	}
}

func TestTransformRecord_nullUsage(t *testing.T) {
	input := `{"timestamp":"2024-01-01T00:00:00Z","message":{"id":"msg1","usage":null}}`
	_, ok := transformRecord([]byte(input), "/home/dev/proj")
	if ok {
		t.Error("expected ok=false when message.usage is null")
	}
}

func TestTransformRecord_invalidJSON(t *testing.T) {
	_, ok := transformRecord([]byte("not json"), "/home/dev/proj")
	if ok {
		t.Error("expected ok=false for invalid JSON")
	}
}

func TestTransformRecord_nilFieldsDropped(t *testing.T) {
	// When optional fields like costUSD are absent/null, they should not appear in output.
	input := `{"timestamp":"2024-01-01T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"m","usage":{"input_tokens":1,"output_tokens":2}}}`
	out, ok := transformRecord([]byte(input), "/home/dev/proj")
	if !ok {
		t.Fatal("expected ok=true")
	}
	var rec map[string]interface{}
	json.Unmarshal(out, &rec)

	// costUSD was not in input → should not appear in output
	if _, found := rec["costUSD"]; found {
		t.Error("costUSD should be absent when not in input")
	}
	// isApiErrorMessage was not in input → should not appear
	if _, found := rec["isApiErrorMessage"]; found {
		t.Error("isApiErrorMessage should be absent when not in input")
	}
}

func TestTransformRecord_cwdRewritten(t *testing.T) {
	input := `{"timestamp":"t","cwd":"/old/path","message":{"usage":{"input_tokens":1}}}`
	out, ok := transformRecord([]byte(input), "/home/dev/newproj")
	if !ok {
		t.Fatal("expected ok=true")
	}
	var rec map[string]interface{}
	json.Unmarshal(out, &rec)
	if rec["cwd"] != "/home/dev/newproj" {
		t.Errorf("cwd = %v, want /home/dev/newproj", rec["cwd"])
	}
}

func TestProjNameFromVolume(t *testing.T) {
	tests := []struct {
		volume string
		want   string
	}{
		{"claude-myproject-abc123def0", "myproject"},
		{"claude-my-project-abc123def0", "my-project"},
		{"custom-volume", "custom-volume"},   // no claude- prefix → full name
		{"claude-nosuffix", "claude-nosuffix"}, // only one dash after claude- prefix
		{"claude-", "claude-"},               // nothing after claude-
	}
	for _, tt := range tests {
		got := ProjNameFromVolume(tt.volume)
		if got != tt.want {
			t.Errorf("ProjNameFromVolume(%q) = %q, want %q", tt.volume, got, tt.want)
		}
	}
}

func TestPickNonNil(t *testing.T) {
	src := map[string]interface{}{
		"a": 1,
		"b": nil,
		"c": "hello",
		"d": nil,
	}
	got := pickNonNil(src, "a", "b", "c")
	if _, ok := got["a"]; !ok {
		t.Error("a missing")
	}
	if _, ok := got["b"]; ok {
		t.Error("b (nil) should be absent")
	}
	if _, ok := got["c"]; !ok {
		t.Error("c missing")
	}
	if _, ok := got["d"]; ok {
		t.Error("d not requested, should be absent")
	}
}

func TestOmitNil(t *testing.T) {
	m := map[string]interface{}{
		"present": "yes",
		"absent":  nil,
	}
	got := omitNil(m)
	if _, ok := got["present"]; !ok {
		t.Error("present key missing")
	}
	if _, ok := got["absent"]; ok {
		t.Error("nil key should be removed")
	}
}
