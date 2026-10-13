package jsonrpc

import (
	"encoding/json"
	"errors"
)

const Version = "2.0"

var ErrUnknownMessage = errors.New("unknown JSON-RPC message shape")

type Request struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
	ID      any    `json:"id,omitempty"`
}

type Response struct {
	JSONRPC string    `json:"jsonrpc"`
	Result  any       `json:"result,omitempty"`
	Error   *RPCError `json:"error,omitempty"`
	ID      any       `json:"id"`
}

type Event struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func NewRequest(method string, params any, id any) Request {
	if params == nil {
		params = struct{}{}
	}
	return Request{
		JSONRPC: Version,
		Method:  method,
		Params:  params,
		ID:      id,
	}
}

func NewResponse(id any, result any) Response {
	return Response{JSONRPC: Version, Result: result, ID: id}
}

func NewErrorResponse(id any, code int, message string, data any) Response {
	return Response{
		JSONRPC: Version,
		Error:   &RPCError{Code: code, Message: message, Data: data},
		ID:      id,
	}
}

func NewEvent(method string, params any) Event {
	return Event{JSONRPC: Version, Method: method, Params: params}
}

func Marshal(v any) ([]byte, error) {
	return json.Marshal(v)
}

func DecodeMessage(data []byte) (any, error) {
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(data, &probe); err != nil {
		return nil, err
	}

	if _, ok := probe["method"]; ok {
		if _, hasID := probe["id"]; hasID {
			var req Request
			if err := json.Unmarshal(data, &req); err != nil {
				return nil, err
			}
			return req, nil
		}

		var evt Event
		if err := json.Unmarshal(data, &evt); err != nil {
			return nil, err
		}
		return evt, nil
	}

	// A response carries an id and no method. JetKVM omits "result" entirely
	// when a handler returns only an error (Result is tagged omitempty), so
	// {"jsonrpc":"2.0","id":1} is a successful void response.
	_, hasResult := probe["result"]
	_, hasID := probe["id"]
	if hasResult || probe["error"] != nil || hasID {
		var resp Response
		if err := json.Unmarshal(data, &resp); err != nil {
			return nil, err
		}
		return resp, nil
	}

	return nil, ErrUnknownMessage
}
