// Runs Porcupine on the histories exported by tests/measure/bench.nim
// (--export:DIR), for a side-by-side table in docs/MEASUREMENTS.md (M23).
//
//	cd tests/measure/porcupine && go run . DIR
//
// Not part of the library or of CI: a measurement tool only.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/anishathalye/porcupine"
)

type event struct {
	Kind    string          `json:"kind"`
	Op      int             `json:"op"`
	Thread  int             `json:"thread"`
	Seq     int64           `json:"seq"`
	Payload json.RawMessage `json:"payload"`
}

type regIn struct {
	Kind  string `json:"kind"`
	Value int    `json:"value"`
}
type regOut struct {
	Value int  `json:"value"`
	Ok    bool `json:"ok"`
}
type queueIn struct {
	Kind  string `json:"kind"`
	Value int    `json:"value"`
}
type queueOut struct {
	Kind  string `json:"kind"`
	Value int    `json:"value"`
}
type kvIn struct {
	Key   int  `json:"key"`
	Value int  `json:"value"`
	Write bool `json:"write"`
}
type kvOut struct {
	Value int `json:"value"`
}

// load returns the operations of one JSON Lines file. Pending operations get
// Return = MaxInt64 and a nil output (each model accepts any output then).
func load(path string, in func(json.RawMessage) interface{}, out func(json.RawMessage) interface{}) []porcupine.Operation {
	f, err := os.Open(path)
	if err != nil {
		panic(err)
	}
	defer f.Close()
	idx := map[int]int{}
	var ops []porcupine.Operation
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<26)
	for sc.Scan() {
		var e event
		if err := json.Unmarshal(sc.Bytes(), &e); err != nil {
			panic(err)
		}
		switch e.Kind {
		case "invoke":
			idx[e.Op] = len(ops)
			ops = append(ops, porcupine.Operation{ClientId: e.Thread, Input: in(e.Payload), Call: e.Seq, Return: math.MaxInt64})
		case "return":
			i := idx[e.Op]
			ops[i].Output = out(e.Payload)
			ops[i].Return = e.Seq
		}
	}
	return ops
}

var registerModel = porcupine.Model{
	Init: func() interface{} { return 0 },
	Step: func(state, input, output interface{}) (bool, interface{}) {
		s := state.(int)
		in := input.(regIn)
		if in.Kind == "write" {
			return true, in.Value
		}
		if output == nil {
			return true, s
		}
		return output.(regOut).Value == s, s
	},
}

var queueModel = porcupine.Model{
	Init: func() interface{} { return []int{} },
	Step: func(state, input, output interface{}) (bool, interface{}) {
		s := state.([]int)
		in := input.(queueIn)
		if in.Kind == "enqueue" {
			n := append(append([]int{}, s...), in.Value)
			return output == nil || output.(queueOut).Kind == "ok", n
		}
		if len(s) == 0 {
			return output == nil || output.(queueOut).Kind == "empty", s
		}
		ok := output == nil || (output.(queueOut).Kind == "value" && output.(queueOut).Value == s[0])
		return ok, append([]int{}, s[1:]...)
	},
	Equal: func(a, b interface{}) bool {
		x, y := a.([]int), b.([]int)
		if len(x) != len(y) {
			return false
		}
		for i := range x {
			if x[i] != y[i] {
				return false
			}
		}
		return true
	},
}

func kvModel(partitioned bool) porcupine.Model {
	m := porcupine.Model{
		Init: func() interface{} { return [4]int{} },
		Step: func(state, input, output interface{}) (bool, interface{}) {
			s := state.([4]int)
			in := input.(kvIn)
			if in.Write {
				s[in.Key] = in.Value
				return true, s
			}
			return output == nil || output.(kvOut).Value == s[in.Key], s
		},
	}
	if partitioned {
		m.Partition = func(h []porcupine.Operation) [][]porcupine.Operation {
			parts := map[int][]porcupine.Operation{}
			for _, op := range h {
				k := op.Input.(kvIn).Key
				parts[k] = append(parts[k], op)
			}
			var keys []int
			for k := range parts {
				keys = append(keys, k)
			}
			sort.Ints(keys)
			var res [][]porcupine.Operation
			for _, k := range keys {
				res = append(res, parts[k])
			}
			return res
		}
	}
	return m
}

func dec[T any](r json.RawMessage) interface{} {
	var v T
	if err := json.Unmarshal(r, &v); err != nil {
		panic(err)
	}
	return v
}

func run(name string, m porcupine.Model, ops []porcupine.Operation) {
	t0 := time.Now()
	res := porcupine.CheckOperationsTimeout(m, ops, 60*time.Second)
	ms := float64(time.Since(t0).Microseconds()) / 1000
	verdict := map[porcupine.CheckResult]string{porcupine.Ok: "Linearizable", porcupine.Illegal: "NotLinearizable", porcupine.Unknown: "Timeout"}[res]
	fmt.Printf("  %-40s %-17s %9.1f ms\n", name, verdict, ms)
}

func main() {
	dir := os.Args[1]
	files, _ := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	sort.Strings(files)
	for _, f := range files {
		base := strings.TrimSuffix(filepath.Base(f), ".jsonl")
		switch {
		case strings.HasPrefix(base, "register_"):
			run(base, registerModel, load(f, dec[regIn], dec[regOut]))
		case strings.HasPrefix(base, "queue_"):
			run(base, queueModel, load(f, dec[queueIn], dec[queueOut]))
		case strings.HasPrefix(base, "kv_"):
			ops := load(f, dec[kvIn], dec[kvOut])
			run(base+" (no partition)", kvModel(false), ops)
			run(base+" (partitioned)", kvModel(true), ops)
		}
	}
}
