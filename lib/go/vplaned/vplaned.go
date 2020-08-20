// Copyright (c) 2020 , AT&T Intellectual Property. All rights reserved.
// SPDX-License-Identifier: MPL-2.0

package vplaned

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"runtime"
	"strings"
	"sync"

	"github.com/danos/vyatta-controller/protobuf/go/VPlanedEnvelope"
	"github.com/danos/vyatta-dataplane/protobuf/go/DataplaneEnvelope"
	"github.com/golang/protobuf/proto"
	zmq "github.com/zeromq/goczmq"
)

const (
	storeEndpoint  = "ipc:///var/run/vyatta/vplaned.socket"
	configEndpoint = "ipc:///var/run/vyatta/vplaned-config.socket"
	defaultDataplaneEndpoint = "ipc:///var/run/vplane.socket"
)

type Error string

func (e Error) Error() string {
	return string(e)
}

const (
	ErrNoControllerResponse = Error("No response from controller")
	ErrConfigStoreFailed = Error("Config store failed")
	ErrNoCommitAction = Error("COMMIT_ACTION not found")
	ErrConfigCommandFailed = Error("Config command failed")
	ErrEmptyConfigCommandResponse = Error("Empty Config Command Response")
	ErrDataplaneNotConnected = Error("Dataplane socket not connected")
)

type Conn struct {
	mu sync.RWMutex

	storeEndpoint, configEndpoint string
	configSocket, storeSocket     *zmq.Sock
}

type dialOpt func(*Conn)

func ConfigEndpoint(address string) dialOpt {
	return func(c *Conn) {
		c.configEndpoint = address
	}
}

func StoreEndpoint(address string) dialOpt {
	return func(c *Conn) {
		c.storeEndpoint = address
	}
}

func Dial(opts ...dialOpt) (*Conn, error) {
	out := Conn{
		storeEndpoint:  storeEndpoint,
		configEndpoint: configEndpoint,
	}
	for _, opt := range opts {
		opt(&out)
	}
	storeSock, err := zmq.NewReq(
		out.storeEndpoint,
		zmq.SockSetLinger(0),
		zmq.SockSetRcvtimeo(10000),
		zmq.SockSetIpv6(1),
	)
	if err != nil {
		return nil, err
	}
	confSock, err := zmq.NewReq(
		out.configEndpoint,
		zmq.SockSetLinger(0),
		zmq.SockSetRcvtimeo(10000),
		zmq.SockSetIpv6(1),
	)
	if err != nil {
		return nil, err
	}

	out.storeSocket = storeSock
	out.configSocket = confSock
	runtime.SetFinalizer(&out, func(c *Conn) {
		c.Close()
	})
	return &out, nil
}

func (c *Conn) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.storeSocket == nil || c.configSocket == nil {
		return nil
	}
	err := c.storeSocket.Disconnect(c.storeEndpoint)
	if err != nil {
		return err
	}
	err = c.configSocket.Disconnect(c.configEndpoint)
	if err != nil {
		return err
	}
	c.storeSocket.Destroy()
	c.configSocket.Destroy()
	c.storeSocket = nil
	c.configSocket = nil
	return nil
}

func (c *Conn) Store(
	path, msgType string,
	msg proto.Message,
	opts ...storeOpt,
) error {
	c.mu.RLock()
	defer c.mu.RUnlock()

	storeOpts := storeOptions{}
	for _, opt := range opts {
		opt(&storeOpts)
	}
	if storeOpts.action == "" {
		storeOpts.action = os.Getenv("COMMIT_ACTION")
	}

	if storeOpts.action == "" {
		return ErrNoCommitAction
	}

	msgData, err := proto.Marshal(msg)
	if err != nil {
		return err
	}

	de := DataplaneEnvelope.DataplaneEnvelope{
		Type: proto.String(msgType),
		Msg:  msgData,
	}

	deData, err := proto.Marshal(&de)
	if err != nil {
		return err
	}

	vpe := VPlanedEnvelope.VPlanedEnvelope{
		Key: proto.String(path),
		Msg: deData,
	}
	if storeOpts.iface != "" {
		vpe.Interface = proto.String(storeOpts.iface)
	}
	if storeOpts.action == "SET" {
		vpe.Action = VPlanedEnvelope.VPlanedEnvelope_SET.Enum()
	} else {
		vpe.Action = VPlanedEnvelope.VPlanedEnvelope_DELETE.Enum()
	}
	vpeData, err := proto.Marshal(&vpe)
	if err != nil {
		return err
	}

	cmd := "protobuf " + base64.StdEncoding.EncodeToString(vpeData)

	jobj := make(map[string]interface{})
	tmp := jobj
	for _, elem := range strings.Split(path, " ") {
		obj := make(map[string]interface{})
		tmp[elem] = obj
		tmp = obj
	}
	tmp["__"+storeOpts.action+"__"] = cmd
	if storeOpts.iface != "" {
		tmp["__INTERFACE__"] = storeOpts.iface
	}
	tmp["__PROTOBUF__"] = true

	encodedMsg, err := json.Marshal(jobj)
	if err != nil {
		return err
	}

	err = c.storeSocket.SendMessage([][]byte{encodedMsg})
	if err != nil {
		return err
	}
	zmsg, err := c.storeSocket.RecvMessage()
	if err != nil {
		return err
	}
	if len(zmsg) == 0 {
		return ErrNoControllerResponse
	}
	if string(zmsg[0]) != "OK" {
		return ErrConfigStoreFailed
	}
	return nil
}

type storeOpt func(*storeOptions)
type storeOptions struct {
	action, iface string
}

func Action(action string) storeOpt {
	return func(o *storeOptions) {
		o.action = action
	}
}

func Interface(iface string) storeOpt {
	return func(o *storeOptions) {
		o.iface = iface
	}
}

type DataplaneList struct {
	Dataplanes []DataplaneData `json:"dataplanes"`
}

type DataplaneData struct {
	Id	uint32 `json:"id"`
	Timeout uint64 `json:"timeout"`
	Local	bool	`json:"local"`
	Connected bool	`json:"connected"`
	Delpend bool `json:"delpend"`
	Ctladdr string `json:"ctladdr"`
	Clocktick  uint32 `json:"clocktick"`
	Connects uint32 `json:"connects"`
	Uuid string `json:"uuid"`
	Sessionid string `json:"sessionid"`
	Control string `json:"control"`
	Interfaces []DataplaneIntf `json:"interfaces"`
}

type DataplaneIntf struct {
	Index uint32 `json:"index"`
	Name string `json:"name"`
	State string `json:"state"`
}

type DataplaneConn struct {
	mu sync.RWMutex
	dpSock  *zmq.Sock

	dp	*DataplaneData
}


func (c *Conn) GetDataplanes() ([]*DataplaneData, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	cmd := []byte("GETVPCONFIG")
	err := c.configSocket.SendMessage([][]byte{cmd})
	zmsg, err := c.configSocket.RecvMessage()

	if err != nil {
		return nil, err
	}
	if len(zmsg) == 0 {
		return nil, ErrNoControllerResponse
	}
	if string(zmsg[0])  != "OK" {
		return nil, ErrConfigCommandFailed
	}
	if len(zmsg) <= 1 {
		return nil, ErrEmptyConfigCommandResponse
	}

	dplist := struct {
		Dataplanes []*DataplaneData `json:"dataplanes"`
	}{}
	err = json.Unmarshal(zmsg[1], &dplist)
	if err != nil {
		return nil, err
	}
	return dplist.Dataplanes, nil
}

func DialDataplane(dp *DataplaneData) (*DataplaneConn, error) {
	dpc := DataplaneConn {
		dp: dp,
	}
	ep := dp.Control
	if ep == "" {
		ep = defaultDataplaneEndpoint
	}
	dpSock, err := zmq.NewReq(
		ep,
		zmq.SockSetLinger(0),
		zmq.SockSetRcvtimeo(10000),
		zmq.SockSetIpv6(1),
	)
	if err != nil {
		return nil, err
	}

	dpc.dpSock = dpSock
	runtime.SetFinalizer(&dpc, func(dpc *DataplaneConn) {
		dpc.Close()
	})
	return &dpc, nil
}

func (dpc *DataplaneConn) Close() error {
	dpc.mu.Lock()
	defer dpc.mu.Unlock()

	if dpc.dpSock == nil {
		return nil
	}
	ep := dpc.dp.Control
	if ep == "" {
		ep = defaultDataplaneEndpoint
	}
	err := dpc.dpSock.Disconnect(ep)
	if err != nil {
		return err
	}
	dpc.dpSock.Destroy()
	dpc.dpSock = nil
	return nil
}

func (dpc *DataplaneConn) PBCmd(msgType string, msg, resp proto.Message) error {
	dpc.mu.RLock()
	defer dpc.mu.RUnlock()

	if dpc.dpSock == nil {
		return ErrDataplaneNotConnected
	}

	msgData, err := proto.Marshal(msg)
	if err != nil {
		return err
	}

	de := DataplaneEnvelope.DataplaneEnvelope{
		Type: proto.String(msgType),
		Msg:  msgData,
	}


	pbout, err := proto.Marshal(&de)
	if err != nil {
		return err
	}

	outm := [][]byte{[]byte("protobuf"), pbout}

	err = dpc.dpSock.SendMessage(outm)
	if err != nil {
		return err
	}

	zmsg, err := dpc.dpSock.RecvMessage()
	if err != nil {
		return err
	}
	rde := DataplaneEnvelope.DataplaneEnvelope {}
	err = proto.Unmarshal(zmsg[0], &rde)
	if err != nil {
		return err
	}
	if resp != nil {
		resp.Reset()
		if rde.Msg != nil {
			return proto.Unmarshal(rde.Msg, resp)
		}
	}
	return nil
}
