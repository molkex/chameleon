package mobile

import "encoding/json"

// unmarshalBatch is a separate helper so events.go can reuse the
// captured request body bytes (echo.Bind only works once and consumes
// the reader). Kept tiny on purpose.
func unmarshalBatch(body []byte, dst *eventBatchRequest) error {
	if len(body) == 0 {
		return nil
	}
	return json.Unmarshal(body, dst)
}

// marshalProperties encodes a single event's properties map so the
// handler can size-check it before handing the batch to the DB layer.
// Returning the encoded bytes is incidental — the size is what we
// actually use — but it keeps the encoder allocation deterministic.
func marshalProperties(props map[string]any) ([]byte, error) {
	return json.Marshal(props)
}
