// Package agy calls the Antigravity LanguageServerService exposed by `agy --hub`.
// The protocol schema is derived from AntiGem v1.0.19 (GPL-3.0); see bridge/LICENSE.
package agy

import (
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/bufbuild/protocompile"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/dynamicpb"
)

//go:embed LanguageServerService.proto
var languageServerProto string

const serviceName = "exa.language_server_pb.LanguageServerService"

type StatusProvider interface {
	GetStatusInfo() (status string, csrfToken string, errorMsg string, logs []string)
}

type Client struct {
	HubPort       string
	SecurityToken string
	Status        StatusProvider
}

type Model struct {
	ID               string `json:"id"`
	Key              string `json:"key"`
	DisplayName      string `json:"displayName"`
	Description      string `json:"description,omitempty"`
	SupportsThinking bool   `json:"supportsThinking"`
}

type ModelsResult struct {
	Models       []Model `json:"models"`
	DefaultModel string  `json:"defaultModel,omitempty"`
}

var (
	descriptorOnce sync.Once
	descriptorFile protoreflect.FileDescriptor
	descriptorErr  error
)

func fileDescriptor() (protoreflect.FileDescriptor, error) {
	descriptorOnce.Do(func() {
		resolver := &protocompile.SourceResolver{Accessor: func(path string) (io.ReadCloser, error) {
			if path != "LanguageServerService.proto" {
				return nil, fmt.Errorf("unknown proto source %q", path)
			}
			return io.NopCloser(strings.NewReader(languageServerProto)), nil
		}}
		compiler := protocompile.Compiler{Resolver: resolver}
		files, err := compiler.Compile(context.Background(), "LanguageServerService.proto")
		if err != nil {
			descriptorErr = fmt.Errorf("compile Antigravity protocol: %w", err)
			return
		}
		descriptorFile = files[0]
	})
	return descriptorFile, descriptorErr
}

// ValidateProtocol checks the embedded upstream schema before enabling AGY routes.
func ValidateProtocol() error {
	_, err := fileDescriptor()
	return err
}

func (c *Client) connection(ctx context.Context) (*grpc.ClientConn, context.Context, error) {
	if c == nil || c.Status == nil {
		return nil, nil, errors.New("Antigravity Hub is not configured")
	}
	status, csrf, hubErr, _ := c.Status.GetStatusInfo()
	if status != "online" || csrf == "" {
		if hubErr != "" {
			return nil, nil, fmt.Errorf("Antigravity Hub is not ready: %s", hubErr)
		}
		return nil, nil, errors.New("Antigravity Hub is offline or missing its CSRF token")
	}
	port := c.HubPort
	if port == "" {
		port = "1235"
	}
	dialCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	conn, err := grpc.DialContext(
		dialCtx,
		"passthrough:///127.0.0.1:"+port,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUserAgent("antiGem-Android-Native"),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, nil, fmt.Errorf("connect to Antigravity Hub: %w", err)
	}
	header := "x-ag" + c.SecurityToken + "_9qx"
	callCtx := metadata.AppendToOutgoingContext(ctx, "x-grpc-web", "1", header, csrf)
	return conn, callCtx, nil
}

func newMessage(name string, body any) (*dynamicpb.Message, error) {
	fd, err := fileDescriptor()
	if err != nil {
		return nil, err
	}
	md := fd.Messages().ByName(protoreflect.Name(name))
	if md == nil {
		return nil, fmt.Errorf("Antigravity message %s is missing from the protocol schema", name)
	}
	msg := dynamicpb.NewMessage(md)
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		if err := protojson.Unmarshal(b, msg); err != nil {
			return nil, fmt.Errorf("encode Antigravity %s request: %w", name, err)
		}
	}
	return msg, nil
}

func methodPath(name string) string { return "/" + serviceName + "/" + name }

func (c *Client) call(ctx context.Context, method, requestName, responseName string, request any) (*dynamicpb.Message, error) {
	conn, callCtx, err := c.connection(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	req, err := newMessage(requestName, request)
	if err != nil {
		return nil, err
	}
	resp, err := newMessage(responseName, nil)
	if err != nil {
		return nil, err
	}
	if err := conn.Invoke(callCtx, methodPath(method), req, resp); err != nil {
		return nil, fmt.Errorf("Antigravity %s: %w", method, err)
	}
	return resp, nil
}

func toJSONMap(msg proto.Message) (map[string]any, error) {
	encoded, err := protojson.Marshal(msg)
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(encoded, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (c *Client) Models(ctx context.Context) (ModelsResult, error) {
	resp, err := c.call(ctx, "GetAvailableModels", "GetAvailableModelsRequest", "GetAvailableModelsResponse", map[string]any{})
	if err != nil {
		return ModelsResult{}, err
	}
	root, err := toJSONMap(resp)
	if err != nil {
		return ModelsResult{}, err
	}
	response, _ := root["response"].(map[string]any)
	modelsByKey, _ := response["models"].(map[string]any)
	if len(modelsByKey) == 0 {
		return ModelsResult{}, errors.New("Antigravity Hub returned no models")
	}

	var ids []string
	if sorts, ok := response["agentModelSorts"].([]any); ok {
		for _, rawSort := range sorts {
			modelSort, _ := rawSort.(map[string]any)
			groups, _ := modelSort["groups"].([]any)
			for _, rawGroup := range groups {
				group, _ := rawGroup.(map[string]any)
				groupIDs, _ := group["modelIds"].([]any)
				for _, rawID := range groupIDs {
					if id, ok := rawID.(string); ok && id != "" && !contains(ids, id) {
						ids = append(ids, id)
					}
				}
			}
		}
	}
	if len(ids) == 0 {
		for key, rawDetails := range modelsByKey {
			details, _ := rawDetails.(map[string]any)
			if details["isInternal"] == true || details["disabled"] == true || details["displayName"] == "" {
				continue
			}
			ids = append(ids, key)
		}
		sort.Strings(ids)
	}

	result := ModelsResult{}
	result.DefaultModel, _ = response["defaultAgentModelId"].(string)
	for _, key := range ids {
		details, _ := modelsByKey[key].(map[string]any)
		if details == nil || details["isInternal"] == true || details["disabled"] == true {
			continue
		}
		modelID, _ := details["model"].(string)
		if modelID == "" || modelID == "MODEL_UNSPECIFIED" {
			modelID = key
		}
		name, _ := details["displayName"].(string)
		if name == "" {
			name = key
		}
		result.Models = append(result.Models, Model{
			ID: modelID, Key: key, DisplayName: name,
			Description:      stringValue(details["description"]),
			SupportsThinking: details["supportsThinking"] == true,
		})
	}
	return result, nil
}

func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

func (c *Client) StartCascade(ctx context.Context, conversationID, workspace, model string) error {
	workspaceURI := ""
	if workspace != "" {
		workspaceURI = workspace
		if !strings.HasPrefix(workspaceURI, "file://") {
			workspaceURI = "file://" + workspaceURI
		}
	}
	body := map[string]any{
		"cascadeId": conversationID,
		"source":    "CORTEX_TRAJECTORY_SOURCE_CASCADE_CLIENT",
	}
	if model != "" {
		body["requestedModel"] = model
	}
	if workspaceURI != "" {
		body["workspaceUris"] = []string{workspaceURI}
		body["overrideWorkspaceUris"] = []string{workspaceURI}
	}
	_, err := c.call(ctx, "StartCascade", "StartCascadeRequest", "StartCascadeResponse", body)
	return err
}

func (c *Client) SendPrompt(ctx context.Context, conversationID, prompt, model string) error {
	config := map[string]any{
		"plannerConfig": map[string]any{
			"toolConfig": map[string]any{
				"runCommand": map[string]any{
					"autoCommandConfig": map[string]any{
						"autoExecutionPolicy": "CASCADE_COMMANDS_AUTO_EXECUTION_OFF",
					},
				},
				"notifyUser": map[string]any{},
			},
			"supportsLatexRendering": true,
			"useAiCredits":           false,
		},
		"executorConfig":            map[string]any{"useCoreDirect": true},
		"conversationHistoryConfig": map[string]any{},
	}
	if model != "" {
		config["plannerConfig"].(map[string]any)["requestedModel"] = map[string]any{"model": model}
	}
	body := map[string]any{
		"cascadeId":     conversationID,
		"items":         []map[string]string{{"text": prompt}},
		"cascadeConfig": config,
		"customAgentSpec": map[string]any{
			"builtinAgent": map[string]any{
				"defaultAgent": map[string]any{"isGoogle": false, "isInteractive": true},
			},
		},
		"deliveryStrategy": "MESSAGE_DELIVERY_STRATEGY_WHEN_IDLE",
	}
	_, err := c.call(ctx, "SendUserCascadeMessage", "SendUserCascadeMessageRequest", "SendUserCascadeMessageResponse", body)
	return err
}

// ResolveInteraction sends a user decision back to the active Antigravity cascade.
func (c *Client) ResolveInteraction(ctx context.Context, cascadeID, trajectoryID string, stepIndex int, interactionType, target string, allow bool, responses []map[string]any) error {
	interaction := map[string]any{"trajectoryId": trajectoryID, "stepIndex": stepIndex}
	switch interactionType {
	case "askQuestion":
		interaction["askQuestion"] = map[string]any{
			"responses": responses,
			"cancelled": !allow,
		}
	case "permission":
		permission := map[string]any{"allow": allow, "scope": "PERMISSION_SCOPE_ONCE"}
		if !allow {
			permission["userDenyInstruction"] = "User declined this action."
		}
		interaction["permission"] = permission
	case "filePermission":
		interaction["filePermission"] = map[string]any{"allow": allow, "scope": "PERMISSION_SCOPE_ONCE", "absolutePathUri": target}
	case "runCommand":
		interaction["runCommand"] = map[string]any{"confirm": allow}
	case "mcp":
		interaction["mcp"] = map[string]any{"confirm": allow}
	case "approvalInteraction":
		interaction["approvalInteraction"] = map[string]any{"confirm": allow}
	case "readUrlContent":
		interaction["readUrlContent"] = map[string]any{"confirm": allow}
	case "browserAction":
		interaction["browserAction"] = map[string]any{"confirm": allow}
	default:
		return fmt.Errorf("unsupported Antigravity interaction %q", interactionType)
	}
	_, err := c.call(ctx, "HandleCascadeUserInteraction", "HandleCascadeUserInteractionRequest", "HandleCascadeUserInteractionResponse", map[string]any{
		"cascadeId":   cascadeID,
		"interaction": interaction,
	})
	return err
}

func terminalWorkspaceURI(workspace string) string {
	if workspace != "" && !strings.HasPrefix(workspace, "file://") {
		return "file://" + workspace
	}
	return workspace
}

func (c *Client) CreateTerminal(ctx context.Context, workspace, conversationID string) (map[string]any, error) {
	response, err := c.call(ctx, "CreateTerminal", "CreateTerminalRequest", "CreateTerminalResponse", map[string]any{
		"workspaceUri":   terminalWorkspaceURI(workspace),
		"conversationId": conversationID,
	})
	if err != nil {
		return nil, err
	}
	root, err := toJSONMap(response)
	if err != nil {
		return nil, err
	}
	terminal, ok := root["terminal"].(map[string]any)
	if !ok || stringValue(terminal["terminalId"]) == "" {
		return nil, errors.New("Antigravity did not return a terminal ID")
	}
	return terminal, nil
}

func (c *Client) SendTerminalInput(ctx context.Context, terminalID string, input []byte, inputStreamID string, inputOffset int64, cols, rows int) error {
	request := map[string]any{
		"terminalId":    terminalID,
		"input":         base64.StdEncoding.EncodeToString(input),
		"inputStreamId": inputStreamID,
		"inputOffset":   inputOffset,
	}
	if cols > 0 && rows > 0 {
		request["resize"] = map[string]any{"cols": cols, "rows": rows}
	}
	_, err := c.call(ctx, "SendTerminalInput", "SendTerminalInputRequest", "SendTerminalInputResponse", request)
	return err
}

func (c *Client) CloseTerminal(ctx context.Context, terminalID string) error {
	_, err := c.call(ctx, "CloseTerminal", "CloseTerminalRequest", "CloseTerminalResponse", map[string]any{
		"terminalId": terminalID,
	})
	return err
}

func (c *Client) StreamTerminalOutput(ctx context.Context, terminalID string, onOutput func(map[string]any) error) error {
	conn, callCtx, err := c.connection(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	req, err := newMessage("StreamTerminalOutputRequest", map[string]any{"terminalId": terminalID})
	if err != nil {
		return err
	}
	if fileDescriptorForMethod("StreamTerminalOutput") == nil {
		return errors.New("Antigravity terminal stream is missing from the protocol schema")
	}
	stream, err := conn.NewStream(callCtx, &grpc.StreamDesc{ServerStreams: true}, methodPath("StreamTerminalOutput"))
	if err != nil {
		return fmt.Errorf("start Antigravity terminal output: %w", err)
	}
	if err := stream.SendMsg(req); err != nil {
		return fmt.Errorf("send Antigravity terminal stream request: %w", err)
	}
	if err := stream.CloseSend(); err != nil {
		return err
	}
	for {
		response, err := newMessage("StreamTerminalOutputResponse", nil)
		if err != nil {
			return err
		}
		if err := stream.RecvMsg(response); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("receive Antigravity terminal output: %w", err)
		}
		output, err := toJSONMap(response)
		if err != nil {
			return err
		}
		if err := onOutput(output); err != nil {
			return err
		}
	}
}

func (c *Client) Stream(ctx context.Context, conversationID string, onUpdate func(map[string]any) error) error {
	conn, callCtx, err := c.connection(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	req, err := newMessage("StreamAgentStateUpdatesRequest", map[string]any{
		"conversationId":      conversationID,
		"subscriberId":        fmt.Sprintf("astra-%d", time.Now().UnixNano()),
		"trajectoryVerbosity": "CLIENTTRAJECTORYVERBOSITY_CLIENT_TRAJECTORY_VERBOSITY_PROD_UI",
	})
	if err != nil {
		return err
	}
	respDesc := fileDescriptorForMethod("StreamAgentStateUpdates")
	if respDesc == nil {
		return errors.New("Antigravity stream method is missing from the protocol schema")
	}
	stream, err := conn.NewStream(callCtx, &grpc.StreamDesc{ServerStreams: true}, methodPath("StreamAgentStateUpdates"))
	if err != nil {
		return fmt.Errorf("start Antigravity update stream: %w", err)
	}
	if err := stream.SendMsg(req); err != nil {
		return fmt.Errorf("send Antigravity stream request: %w", err)
	}
	if err := stream.CloseSend(); err != nil {
		return fmt.Errorf("close Antigravity stream request: %w", err)
	}
	for {
		response, err := newMessage("StreamAgentStateUpdatesResponse", nil)
		if err != nil {
			return err
		}
		if err := stream.RecvMsg(response); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("receive Antigravity update: %w", err)
		}
		update, err := toJSONMap(response)
		if err != nil {
			return err
		}
		if err := onUpdate(update); err != nil {
			return err
		}
	}
}

func fileDescriptorForMethod(name string) protoreflect.MethodDescriptor {
	fd, err := fileDescriptor()
	if err != nil {
		return nil
	}
	svc := fd.Services().ByName("LanguageServerService")
	if svc == nil {
		return nil
	}
	return svc.Methods().ByName(protoreflect.Name(name))
}
