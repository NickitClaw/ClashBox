//go:build cgo && ohos

package main

//#include "bridge.h"
import "C"
import (
	"core/state"
	"encoding/json"
	"strings"
	"sync"
	"unsafe"

	napi "github.com/likuai2010/ohos-napi"
	"github.com/likuai2010/ohos-napi/entry"
	"github.com/likuai2010/ohos-napi/js"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func initClash(env js.Env, this js.Value, args []js.Value) any {
	homeDirStr, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return handleInitClash(homeDirStr)
}

type safeCallback struct {
	mu sync.Mutex
	fn C.napi_threadsafe_function
}

func newSafeCallback(env js.Env, callback js.Value) *safeCallback {
	return &safeCallback{fn: C.bridge_create(C.napi_env(unsafe.Pointer(env.Env)), C.napi_value(unsafe.Pointer(callback.Value)))}
}
func (c *safeCallback) close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fn != nil {
		C.bridge_release(c.fn)
		c.fn = nil
	}
}
func (c *safeCallback) protect(fd Fd) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fn == nil || C.bridge_send_fd(c.fn, C.int64_t(fd.Id), C.int64_t(fd.Value)) == 0 {
		acknowledgeFd(fd.Id, false)
	}
}
func (c *safeCallback) log(text string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fn == nil {
		return
	}
	value := C.CString(text)
	defer C.free(unsafe.Pointer(value))
	C.bridge_send_log(c.fn, value)
}

var nativeOpMu sync.Mutex
var protectCallback *safeCallback
var logCallback *safeCallback

func startTun(env js.Env, this js.Value, args []js.Value) any {
	tunFd, _ := napi.GetValueInt32(env.Env, args[0].Value)
	callback := newSafeCallback(env, args[1])
	promise := env.NewPromise()
	go func() {
		nativeOpMu.Lock()
		defer nativeOpMu.Unlock()
		stopErr := StopTun()
		protectCallback.close()
		protectCallback = callback
		if stopErr != nil {
			callback.close()
			promise.Reject(stopErr.Error())
			return
		}
		if callback.fn == nil {
			promise.Reject("cannot create protect callback")
			return
		}
		if err := StartTUN(int(tunFd), callback.protect); err != nil {
			callback.close()
			promise.Reject(err.Error())
			return
		}
		promise.Resolve(true)
	}()
	return promise
}
func stopTun(env js.Env, this js.Value, args []js.Value) any {
	promise := env.NewPromise()
	go func() {
		nativeOpMu.Lock()
		defer nativeOpMu.Unlock()
		err := StopTun()
		protectCallback.close()
		protectCallback = nil
		if err != nil {
			promise.Reject(err.Error())
			return
		}
		promise.Resolve(nil)
	}()
	return promise
}

func validateConfig(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	bytes := []byte(paramsString)
	promise := env.NewPromise()
	go func() {
		promise.Resolve(handleValidateConfig(bytes))
	}()
	return promise
}

func updateConfig(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)

	promise := env.NewPromise()
	bytes := []byte(paramsString)
	go func() {
		promise.Resolve(handleUpdateConfig(bytes))
	}()
	return promise
}

func getProxies(env js.Env, this js.Value, args []js.Value) any {
	return handleGetProxies()
}

func changeProxy(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleChangeProxy(paramsString, func(value string) {
		promise.Resolve(value)
	})
	return promise
}

func getTraffic(env js.Env, this js.Value, args []js.Value) any {
	onlyProxy := true
	return handleGetTraffic(onlyProxy)
}
func getTotalTraffic(env js.Env, this js.Value, args []js.Value) any {
	onlyProxy := true
	return handleGetTotalTraffic(onlyProxy)
}
func resetTraffic(env js.Env, this js.Value, args []js.Value) any {
	handleResetTraffic()
	return nil
}
func forceGc(env js.Env, this js.Value, args []js.Value) any {
	handleForceGc()
	return nil
}
func asyncTestDelay(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleAsyncTestDelay(paramsString, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func getExternalProviders(env js.Env, this js.Value, args []js.Value) any {
	return handleGetExternalProviders()
}
func getExternalProvider(env js.Env, this js.Value, args []js.Value) any {
	externalProviderName, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return handleGetExternalProvider(externalProviderName)
}
func updateGeoData(env js.Env, this js.Value, args []js.Value) any {
	geoType, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	geoName, _ := napi.GetValueStringUtf8(env.Env, args[1].Value)
	promise := env.NewPromise()
	handleUpdateGeoData(geoType, geoName, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func updateExternalProvider(env js.Env, this js.Value, args []js.Value) any {
	providerName, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleUpdateExternalProvider(providerName, func(value string) {
		promise.Resolve(value)
	})
	return promise
}

func sideLoadExternalProvider(env js.Env, this js.Value, args []js.Value) any {
	providerName, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	dataChar, _ := napi.GetValueStringUtf8(env.Env, args[1].Value)
	data := []byte(dataChar)
	promise := env.NewPromise()
	handleSideLoadExternalProvider(providerName, data, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func getConnections(env js.Env, this js.Value, args []js.Value) any {
	return handleGetConnections()
}

func closeConnections(env js.Env, this js.Value, args []js.Value) any {
	return handleCloseConnections()
}

func closeConnection(env js.Env, this js.Value, args []js.Value) any {
	connectionId, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return handleCloseConnection(connectionId)
}

func startLog(env js.Env, this js.Value, args []js.Value) any {
	handleStopLog()
	logCallback.close()
	logCallback = newSafeCallback(env, args[0])
	handleStartLog(logCallback.log)
	return nil
}
func stopLog(env js.Env, this js.Value, args []js.Value) any {
	handleStopLog()
	logCallback.close()
	logCallback = nil
	return nil
}
func getCountryCode(env js.Env, this js.Value, args []js.Value) any {
	ip, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	handleGetCountryCode(ip, func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func getMemory(env js.Env, this js.Value, args []js.Value) any {
	promise := env.NewPromise()
	handleGetMemory(func(value string) {
		promise.Resolve(value)
	})
	return promise
}
func updateDns(env js.Env, this js.Value, args []js.Value) any {
	dnsList, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	promise := env.NewPromise()
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
		promise.Resolve(nil)
	}()
	return promise
}
func setState(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	err := json.Unmarshal([]byte(paramsString), state.CurrentState)
	if err != nil {
		return nil
	}
	return nil
}
func setProcessMap(env js.Env, this js.Value, args []js.Value) any {
	paramsString, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	return SetProcessMap(paramsString)
}

func getVpnOptions(env js.Env, this js.Value, args []js.Value) any {
	return GetVpnOptions()
}
func getCurrentProfileName(env js.Env, this js.Value, args []js.Value) any {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func setFdMap(env js.Env, this js.Value, args []js.Value) any {
	id, _ := napi.GetValueDouble(env.Env, args[0].Value)
	success := true
	if len(args) > 1 {
		success, _ = napi.GetValueBool(env.Env, args[1].Value)
	}
	acknowledgeFd(int64(id), success)
	return nil
}

var messageHandlers = map[string]js.TsFunc{}

func registerMessage(env js.Env, this js.Value, args []js.Value) any {
	messageHandlers["messageTsfn"] = env.CreateThreadsafeFunction(args[0], "messageTsfn")
	return nil
}
func getRequestList(env js.Env, this js.Value, args []js.Value) any {
	json, _ := json.Marshal(reqeustList)
	return env.ValueOf(string(json))
}

func clearRequestList(env js.Env, this js.Value, args []js.Value) any {
	reqeustList = []statistic.Tracker{}
	return env.ValueOf("")
}
func startListener(env js.Env, this js.Value, args []js.Value) any {
	handleStartListener()
	return env.ValueOf("")
}
func stopListener(env js.Env, this js.Value, args []js.Value) any {
	handleStopListener()
	return env.ValueOf("")
}
func startIpc(env js.Env, this js.Value, args []js.Value) any {
	path, _ := napi.GetValueStringUtf8(env.Env, args[0].Value)
	go startIpcProxy(path)
	return env.ValueOf("")
}

func init() {
	entry.Export("initClash", js.AsCallback(initClash))
	entry.Export("startTun", js.AsCallback(startTun))
	entry.Export("setFdMap", js.AsCallback(setFdMap))
	entry.Export("stopTun", js.AsCallback(stopTun))
	entry.Export("forceGc", js.AsCallback(forceGc))
	entry.Export("validateConfig", js.AsCallback(validateConfig))
	entry.Export("updateConfig", js.AsCallback(updateConfig))
	entry.Export("getTraffic", js.AsCallback(getTraffic))
	entry.Export("getTotalTraffic", js.AsCallback(getTotalTraffic))
	entry.Export("resetTraffic", js.AsCallback(resetTraffic))
	entry.Export("getProxies", js.AsCallback(getProxies))
	entry.Export("changeProxy", js.AsCallback(changeProxy))
	entry.Export("asyncTestDelay", js.AsCallback(asyncTestDelay))
	entry.Export("getConnections", js.AsCallback(getConnections))
	entry.Export("closeConnections", js.AsCallback(closeConnections))
	entry.Export("closeConnection", js.AsCallback(closeConnection))
	entry.Export("updateExternalProvider", js.AsCallback(updateExternalProvider))
	entry.Export("sideLoadExternalProvider", js.AsCallback(sideLoadExternalProvider))
	entry.Export("getExternalProviders", js.AsCallback(getExternalProviders))
	entry.Export("getVpnOptions", js.AsCallback(getVpnOptions))
	entry.Export("getCurrentProfileName", js.AsCallback(getCurrentProfileName))
	entry.Export("setProcessMap", js.AsCallback(setProcessMap))
	entry.Export("updateGeoData", js.AsCallback(updateGeoData))
	entry.Export("startListener", js.AsCallback(startListener))
	entry.Export("stopListener", js.AsCallback(stopListener))
	entry.Export("startIpc", js.AsCallback(startIpc))

	entry.Export("updateDns", js.AsCallback(updateDns))
	entry.Export("startLog", js.AsCallback(startLog))
	entry.Export("stopLog", js.AsCallback(stopLog))
	entry.Export("registerMessage", js.AsCallback(registerMessage))
	entry.Export("getRequestList", js.AsCallback(getRequestList))
	entry.Export("clearRequestList", js.AsCallback(clearRequestList))

	entry.Export("getCountryCode", js.AsCallback(getCountryCode))
	entry.Export("getMemory", js.AsCallback(getMemory))

}

func sendMessage(message Message) {
	_, err := message.Json()
	if err != nil {
		return
	}
	runLock.Lock()
	defer runLock.Unlock()
	// if handler, ok := messageHandlers["messageTsfn"]; ok {
	// 	key := handler.Env.ValueOf("")
	// 	value := handler.Env.ValueOf(res)
	// 	handler.Call(key, value)
	// }
}

func main() {
}
