package com.androp.approvals

import org.junit.Assert.assertEquals
import org.junit.Test

class PairingFingerprintTest {
    @Test fun matchesTheMacBonjourName() {
        // Same vector as MobileApprovalBridgeTests on the Mac: SHA-256 of 32 bytes of 0x07.
        assertEquals("4bb06f8e", ApprovalPairing.fingerprint(ByteArray(32) { 7 }))
    }
}
