package main

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestDoSomething(t *testing.T) {
	assert.Equal(t, doSomething(), 0)
}
