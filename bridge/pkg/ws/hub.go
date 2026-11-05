package ws

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"

	"gemini-server/pkg/agy"
	"gemini-server/pkg/config"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return true // Allow all origins (Android app & webview)
	},
}

type ClientConn struct {
	ws *websocket.Conn
	mu sync.Mutex
}

func (c *ClientConn) SendJSON(v interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ws.WriteJSON(v)
}

type HubStatusProvider interface {
	GetStatusInfo() (status string, csrfToken string, errorMsg string, logs []string)
}

type Hub struct {
	Cfg        *config.Config
	StatusProv HubStatusProvider
	AgyClient  *agy.Client
	HubPort    string
	clients    map[*ClientConn]bool
	mu         sync.RWMutex
}

func NewHub(cfg *config.Config) *Hub {
	return &Hub{
		Cfg:     cfg,
		HubPort: "1235",
		clients: make(map[*ClientConn]bool),
	}
}

func (h *Hub) Broadcast(msg interface{}) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for client := range h.clients {
		_ = client.SendJSON(msg)
	}
}

func (h *Hub) BroadcastHubStatus(status string, port string, csrfToken string, errorMsg string, logs []string) {
	h.Broadcast(map[string]interface{}{
		"type":       "hub_status",
		"status":     status,
		"port":       port,
		"csrf_token": csrfToken,
		"error":      errorMsg,
		"logs":       logs,
	})
}

// Close disconnects all active WebSocket clients cleanly.
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for client := range h.clients {
		_ = client.ws.Close()
	}
	h.clients = make(map[*ClientConn]bool)
}

type clientMessage struct {
	Type            string           `json:"type"` // "ping", "attach_session", "abort"
	ConversationID  string           `json:"conversationId"`
	Model           string           `json:"model"`
	Prompt          string           `json:"prompt"`
	WorkspaceDir    string           `json:"workspaceDir"`
	IsNew           bool             `json:"isNew"`
	TrajectoryID    string           `json:"trajectoryId"`
	StepIndex       int              `json:"stepIndex"`
	InteractionType string           `json:"interactionType"`
	Target          string           `json:"target"`
	Allow           bool             `json:"allow"`
	Responses       []map[string]any `json:"responses"`
	TerminalID      string           `json:"terminalId"`
	Input           string           `json:"input"`
	Cols            int              `json:"cols"`
	Rows            int              `json:"rows"`
}

// ServeTerminalWS proxies an AGY Hub terminal over a dedicated WebSocket.
func (h *Hub) ServeTerminalWS(w http.ResponseWriter, r *http.Request) {
	rawConn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		fmt.Printf("[Terminal WS] Upgrade error: %v\n", err)
		return
	}
	client := &ClientConn{ws: rawConn}
	ctx, cancel := context.WithCancel(context.Background())
	defer func() {
		cancel()
		_ = rawConn.Close()
	}()
	var terminalID string
	inputStreamID := uuid.NewString()
	var inputOffset int64
	defer func() {
		if terminalID != "" && h.AgyClient != nil {
			closeCtx, closeCancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer closeCancel()
			_ = h.AgyClient.CloseTerminal(closeCtx, terminalID)
		}
	}()

	for {
		_, msgBytes, err := rawConn.ReadMessage()
		if err != nil {
			return
		}
		var msg clientMessage
		if err := json.Unmarshal(msgBytes, &msg); err != nil {
			continue
		}
		switch msg.Type {
		case "terminal_create":
			if h.AgyClient == nil {
				_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": "Antigravity terminal is unavailable"})
				continue
			}
			if terminalID != "" {
				_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": "this connection already owns a terminal"})
				continue
			}
			createCtx, createCancel := context.WithTimeout(ctx, 20*time.Second)
			terminal, err := h.AgyClient.CreateTerminal(createCtx, msg.WorkspaceDir, msg.ConversationID)
			createCancel()
			if err != nil {
				_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": err.Error()})
				continue
			}
			terminalID = stringValue(terminal["terminalId"])
			_ = client.SendJSON(map[string]any{"type": "terminal_created", "terminal": terminal})
			go h.streamTerminal(ctx, client, terminalID)

		case "terminal_input", "terminal_resize":
			if terminalID == "" || h.AgyClient == nil {
				_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": "terminal is not connected"})
				continue
			}
			input := []byte(nil)
			if msg.Type == "terminal_input" {
				input = []byte(msg.Input)
			}
			inputCtx, inputCancel := context.WithTimeout(ctx, 15*time.Second)
			err := h.AgyClient.SendTerminalInput(inputCtx, terminalID, input, inputStreamID, inputOffset, msg.Cols, msg.Rows)
			inputCancel()
			if err != nil {
				_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": err.Error()})
			} else {
				inputOffset += int64(len(input))
			}

		case "terminal_close":
			if terminalID != "" && h.AgyClient != nil {
				closeCtx, closeCancel := context.WithTimeout(ctx, 10*time.Second)
				err := h.AgyClient.CloseTerminal(closeCtx, terminalID)
				closeCancel()
				if err != nil {
					_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": err.Error()})
				}
				terminalID = ""
			}
			_ = client.SendJSON(map[string]any{"type": "terminal_closed"})
			return
		}
	}
}

func (h *Hub) streamTerminal(ctx context.Context, client *ClientConn, terminalID string) {
	err := h.AgyClient.StreamTerminalOutput(ctx, terminalID, func(output map[string]any) error {
		return client.SendJSON(map[string]any{"type": "terminal_output", "terminalId": terminalID, "data": output})
	})
	if err != nil && ctx.Err() == nil {
		_ = client.SendJSON(map[string]any{"type": "terminal_error", "error": err.Error()})
		return
	}
	if ctx.Err() == nil {
		_ = client.SendJSON(map[string]any{"type": "terminal_exit", "terminalId": terminalID})
	}
}

func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request) {
	rawConn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		fmt.Printf("[WS] Upgrade error: %v\n", err)
		return
	}
	client := &ClientConn{ws: rawConn}

	h.mu.Lock()
	h.clients[client] = true
	prov := h.StatusProv
	port := h.HubPort
	h.mu.Unlock()

	// Send initial hub status immediately on connection
	if prov != nil {
		st, csrf, errMsg, logs := prov.GetStatusInfo()
		_ = client.SendJSON(map[string]interface{}{
			"type":       "hub_status",
			"status":     st,
			"port":       port,
			"csrf_token": csrf,
			"error":      errMsg,
			"logs":       logs,
		})
	}

	defer func() {
		h.mu.Lock()
		delete(h.clients, client)
		h.mu.Unlock()
		_ = rawConn.Close()
	}()

	for {
		_, msgBytes, err := rawConn.ReadMessage()
		if err != nil {
			break
		}

		var msg clientMessage
		if err := json.Unmarshal(msgBytes, &msg); err != nil {
			continue
		}

		switch msg.Type {
		case "ping":
			_ = client.SendJSON(map[string]string{"type": "pong"})

		case "attach_session":
			_ = client.SendJSON(map[string]interface{}{
				"type":           "session_attached",
				"conversationId": msg.ConversationID,
				"isRunning":      false,
			})
			_ = client.SendJSON(map[string]interface{}{
				"type":     "done",
				"exitCode": 0,
			})

		case "abort":
			_ = client.SendJSON(map[string]interface{}{
				"type":           "aborted",
				"conversationId": msg.ConversationID,
			})

		case "send_prompt":
			go h.serveAgyPrompt(client, msg)

		case "resolve_interaction":
			h.resolveAgyInteraction(client, msg)
		}
	}
}

func (h *Hub) resolveAgyInteraction(client *ClientConn, msg clientMessage) {
	if h.AgyClient == nil || msg.ConversationID == "" || msg.StepIndex < 0 {
		_ = client.SendJSON(map[string]any{"type": "error", "error": "invalid Antigravity interaction"})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := h.AgyClient.ResolveInteraction(ctx, msg.ConversationID, msg.TrajectoryID, msg.StepIndex, msg.InteractionType, msg.Target, msg.Allow, msg.Responses); err != nil {
		_ = client.SendJSON(map[string]any{"type": "error", "error": err.Error()})
		return
	}
	_ = client.SendJSON(map[string]any{"type": "interaction_resolved", "stepIndex": msg.StepIndex})
}

var errAgyTurnComplete = errors.New("Antigravity turn complete")

func (h *Hub) serveAgyPrompt(client *ClientConn, msg clientMessage) {
	if h.AgyClient == nil {
		_ = client.SendJSON(map[string]interface{}{"type": "error", "error": "Antigravity chat is unavailable in this bridge build"})
		return
	}
	if msg.Prompt == "" {
		_ = client.SendJSON(map[string]interface{}{"type": "error", "error": "prompt is required"})
		return
	}
	conversationID := msg.ConversationID
	if conversationID == "" {
		conversationID = uuid.NewString()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Minute)
	defer cancel()
	if msg.IsNew {
		if err := h.AgyClient.StartCascade(ctx, conversationID, msg.WorkspaceDir, msg.Model); err != nil {
			_ = client.SendJSON(map[string]interface{}{"type": "error", "error": err.Error()})
			return
		}
	}
	if err := h.AgyClient.SendPrompt(ctx, conversationID, msg.Prompt, msg.Model); err != nil {
		_ = client.SendJSON(map[string]interface{}{"type": "error", "error": err.Error()})
		return
	}
	_ = client.SendJSON(map[string]interface{}{
		"type":           "session_attached",
		"conversationId": conversationID,
		"isRunning":      true,
	})

	latestUserStep := -1
	sawCurrentResponse := false
	err := h.AgyClient.Stream(ctx, conversationID, func(update map[string]any) error {
		if updateBody, ok := update["update"].(map[string]any); ok {
			trajectory, _ := updateBody["mainTrajectoryUpdate"].(map[string]any)
			if stepsUpdate, ok := trajectory["stepsUpdate"].(map[string]any); ok {
				steps, _ := stepsUpdate["steps"].([]any)
				indices, _ := stepsUpdate["indices"].([]any)
				for i, rawStep := range steps {
					step, _ := rawStep.(map[string]any)
					metadata, _ := step["metadata"].(map[string]any)
					source, _ := metadata["sourceTrajectoryStepInfo"].(map[string]any)
					stepIndex, _ := source["stepIndex"].(float64)
					if stepIndex == 0 && i < len(indices) {
						stepIndex, _ = indices[i].(float64)
					}
					if step["userInput"] != nil || step["type"] == "CORTEX_STEP_TYPE_USER_INPUT" {
						if int(stepIndex) > latestUserStep {
							latestUserStep = int(stepIndex)
							sawCurrentResponse = false
						}
					}
					if int(stepIndex) > latestUserStep && (step["plannerResponse"] != nil || step["errorMessage"] != nil) {
						sawCurrentResponse = true
					}
				}
			}
			if updateBody["fullyIdle"] == true && sawCurrentResponse {
				if err := client.SendJSON(map[string]any{"type": "agy_event", "data": update}); err != nil {
					return err
				}
				return errAgyTurnComplete
			}
		}
		return client.SendJSON(map[string]any{"type": "agy_event", "data": update})
	})
	if err != nil && !errors.Is(err, errAgyTurnComplete) {
		_ = client.SendJSON(map[string]interface{}{"type": "error", "error": err.Error()})
		return
	}
	_ = client.SendJSON(map[string]interface{}{"type": "done", "conversationId": conversationID, "exitCode": 0})
}
