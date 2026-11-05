package com.kerdly.sdk.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

class StorageTest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun theFileStoreReplacesFilesAndCreatesItsDirectory() {
        val dir = File(tmp.root, "no_backup/kerdly")
        val store = FileStore(dir)
        assertNull(store.read("queue.json"))
        assertTrue(store.write("queue.json", "one"))
        assertTrue(store.write("queue.json", "two ✓"))
        assertEquals("two ✓", store.read("queue.json"))
        assertFalse("no temp file is left behind", File(dir, "queue.json.tmp").exists())
        store.delete("queue.json")
        assertNull(store.read("queue.json"))
    }

    @Test
    fun aWriteThatCannotHappenReturnsFalse() {
        val blocker = tmp.newFile("blocker")
        assertFalse(FileStore(File(blocker, "kerdly")).write("x", "y"))
    }

    @Test
    fun theSdkDirectoryIsKerdlyAndAdoptsTheAfrDirectoryOfBuildsBefore010() {
        val fresh = tmp.newFolder("fresh")
        assertEquals(File(fresh, "kerdly"), sdkDirectory(fresh))
        assertFalse("nothing is created until a write", File(fresh, "kerdly").exists())

        val updated = tmp.newFolder("updated")
        val oldId = "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71"
        assertTrue(InstallId.persist(FileStore(File(updated, "afr")), oldId))
        val dir = sdkDirectory(updated)
        assertEquals(File(updated, "kerdly"), dir)
        assertFalse(File(updated, "afr").exists())
        val loaded = InstallId.load(FileStore(dir))
        assertFalse(loaded.created)
        assertEquals(oldId, loaded.id)

        val both = tmp.newFolder("both")
        assertTrue(File(both, "kerdly").mkdirs() && File(both, "afr").mkdirs())
        assertEquals(File(both, "kerdly"), sdkDirectory(both))
        assertTrue("an afr directory next to kerdly is left alone", File(both, "afr").isDirectory)
    }

    @Test
    fun theInstallIdIsCreatedOnceAndReused() {
        val store = FileStore(tmp.newFolder("kerdly"))
        val first = InstallId.load(store)
        assertTrue(first.created)
        assertTrue(InstallId.isValid(first.id))
        assertEquals('4', first.id[14]) // UUID version 4
        assertTrue("load alone never writes", InstallId.load(store).created)
        assertTrue(InstallId.persist(store, first.id))
        val second = InstallId.load(store)
        assertFalse(second.created)
        assertEquals(first.id, second.id)
    }

    @Test
    fun aCorruptIdFileMeansANewInstall() {
        val store = MemoryStore()
        store.files[StoreFiles.INSTALL_ID] = "garbage"
        val r = InstallId.load(store) { "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71" }
        assertTrue(r.created)
        assertEquals("4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71", r.id)

        store.files[StoreFiles.INSTALL_ID] = " 4D5E6F7A-8B9C-4D0E-9F1A-2B3C4D5E6F71\n"
        val upper = InstallId.load(store) { error("must not create") }
        assertFalse(upper.created)
        assertEquals("4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f71", upper.id)
    }

    @Test(expected = IOException::class)
    fun anUnreadableIdFileIsAnErrorNotANewInstall() {
        val unreadable = object : Store {
            override fun read(name: String): String? = throw IOException("EIO")
            override fun write(name: String, content: String) = true
            override fun delete(name: String) {}
        }
        InstallId.load(unreadable)
    }

    @Test
    fun theStateRoundTripsAndBelongsToItsInstall() {
        val s = SdkState()
        s.userId = "u1"
        s.analytics = false
        s.appAccountToken = "\$SuperwallAlias:abc"
        s.partner = linkedMapOf("meta_anon_id" to "X")
        s.firstLaunchAt = 10
        s.installedAt = 5
        s.installEventId = "e"
        s.installAcked = true
        s.referrerDone = true
        s.referrerAttempts = 2
        s.metaDone = true
        s.adIdReadAt = 11
        s.adIdHash = "h"
        s.lat = false
        s.contextHash = "c"
        s.retryAttempt = 3
        s.retryNextAt = 99
        s.nextSeq = 42
        val text = s.serialize("i1")
        val back = SdkState.parse(text, "i1")!!
        assertEquals(text, back.serialize("i1"))
        assertNull(SdkState.parse(text, "i2"))
        assertNull(SdkState.parse("{", "i1"))
    }

    @Test
    fun pendingLinksExpireAndStayBounded() {
        val p = PendingLinks()
        for (i in 1..25) p.add(JSONObject().put("id", "id$i").put("seq", i).toString(), now = 1_000L * i)
        assertEquals(PendingLinks.MAX, p.entries().size)
        assertEquals("id6", p.entries().first().id)
        p.add(JSONObject().put("id", "id25").toString(), now = 0)
        assertEquals(PendingLinks.MAX, p.entries().size)
        assertEquals(25L, p.maxSeq())

        assertTrue(p.remove(listOf("id6", "nope")))
        assertFalse(p.remove(listOf("nope")))
        val back = PendingLinks.parse(p.serialize())
        assertEquals(p.entries().map { it.id }, back.entries().map { it.id })

        assertTrue(back.expire(now = 20_500L + PendingLinks.TTL_MS))
        assertEquals(listOf("id21", "id22", "id23", "id24", "id25"), back.entries().map { it.id })
    }

    @Test
    fun reportedPurchasesKeepHashesOnly() {
        val r = ReportedPurchases()
        val hash = ReportedPurchases.tokenHash("secret-token")
        r.add(hash)
        assertEquals(40, hash.length)
        val back = ReportedPurchases.parse(r.serialize())
        assertTrue(back.contains(hash))
        assertFalse(r.serialize().contains("secret-token"))
        assertFalse(back.contains(ReportedPurchases.tokenHash("other")))
    }

    @Test
    fun sha1AndUtf8Length() {
        assertEquals("a9993e364706816aba3e25717850c26c9cd0d89d", sha1Hex("abc"))
        assertEquals(3, utf8Length("abc"))
        assertEquals(2, utf8Length("ñ"))
        assertEquals(3, utf8Length("✓"))
        assertEquals(4, utf8Length("😀"))
    }
}
