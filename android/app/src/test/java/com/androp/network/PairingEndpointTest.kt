package com.androp.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingEndpointTest {
    private val payload = "androp://pair?v=1&host=192.0.2.18&port=18989&code=012345"

    @Test fun scannedCodePreservesThePortAndLeadingZero() {
        val (endpoint, code) = PairingEndpoint.scanned(payload)
        assertEquals(PairingEndpoint("192.0.2.18", 18989), endpoint)
        assertEquals("012345", code)
        assertEquals("192.0.2.18:18989", endpoint.address)
    }

    @Test fun manualAddressSupportsTheDefaultAndCustomPorts() {
        assertEquals(PairingEndpoint("192.0.2.18", 8989), PairingEndpoint.manual("192.0.2.18"))
        assertEquals(PairingEndpoint("my-mac.local", 18989), PairingEndpoint.manual("my-mac.local:18989"))
        assertEquals(PairingEndpoint("fd00::1", 18989), PairingEndpoint.manual("[fd00::1]:18989"))
        assertThrows(IllegalArgumentException::class.java) { PairingEndpoint.manual("192.0.2.18:70000") }
    }

    @Test fun malformedAndUnrelatedCodesDontConnect() {
        for (value in listOf(
            "https://192.0.2.18", "$payload&code=654321", payload.replace("v=1", "v=2"),
            payload.replace("18989", "0"), payload.replace("192.0.2.18", "127.0.0.1"),
            payload.replace("192.0.2.18", "192.0.2.256"), payload.replace("012345", "12345")
        )) {
            assertThrows(IllegalArgumentException::class.java) { PairingEndpoint.scanned(value) }
        }
    }
}
