//
//  EnteCrypto.swift
//  immich-share
//
//  Cryptographic utilities for Ente's end-to-end encryption.
//  Uses libsodium via swift-sodium for XSalsa20-Poly1305 (secretbox)
//  and XChaCha20-Poly1305 (secretstream) operations.
//

import Foundation
import Sodium

enum EnteCrypto {

    private static let sodium = Sodium()

    // MARK: - Base58 Decoding (Bitcoin alphabet)

    private static let base58Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    static func decodeBase58(_ string: String) -> Data? {
        let alphabetArray = Array(base58Alphabet)
        var result: [UInt8] = [0]

        for char in string {
            guard let index = alphabetArray.firstIndex(of: char) else { return nil }
            var carry = alphabetArray.distance(from: alphabetArray.startIndex, to: index)
            for j in 0..<result.count {
                carry += Int(result[j]) * 58
                result[j] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                result.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }

        // Leading '1' characters represent leading zero bytes
        for char in string {
            if char != "1" { break }
            result.append(0)
        }

        return Data(result.reversed())
    }

    // MARK: - SecretBox (XSalsa20-Poly1305)

    /// Decrypt data encrypted with crypto_secretbox_open_easy.
    /// - Parameters:
    ///   - ciphertext: The encrypted data (includes 16-byte MAC appended by secretbox)
    ///   - nonce: 24-byte nonce
    ///   - key: 32-byte key
    /// - Returns: Decrypted plaintext, or nil on failure
    static func decryptSecretBox(ciphertext: Data, nonce: Data, key: Data) -> Data? {
        let ciphertextBytes = Array(ciphertext)
        let nonceBytes = Array(nonce)
        let keyBytes = Array(key)

        guard nonceBytes.count == 24, keyBytes.count == 32 else { return nil }

        guard let decrypted = sodium.secretBox.open(
            authenticatedCipherText: ciphertextBytes,
            secretKey: keyBytes,
            nonce: nonceBytes
        ) else {
            return nil
        }

        return Data(decrypted)
    }

    // MARK: - SecretStream (XChaCha20-Poly1305)

    /// Decrypt data encrypted with crypto_secretstream_xchacha20poly1305.
    /// The encrypted data consists of chunks, each with a 17-byte overhead (1 byte tag + 16 byte MAC).
    /// - Parameters:
    ///   - encryptedData: The encrypted payload (without the header)
    ///   - header: 24-byte stream header
    ///   - key: 32-byte key
    /// - Returns: Decrypted plaintext, or nil on failure
    static func decryptStream(encryptedData: Data, header: Data, key: Data) -> Data? {
        let headerBytes = Array(header)
        let keyBytes = Array(key)

        guard headerBytes.count == 24, keyBytes.count == 32 else { return nil }

        guard let stream = sodium.secretStream.xchacha20poly1305.initPull(
            secretKey: keyBytes,
            header: headerBytes
        ) else {
            return nil
        }

        // Ente uses a chunk size of 4MB for encryption
        // Each encrypted chunk has 17 bytes overhead (ABYTES = 16 + 1 tag byte)
        let decryptionChunkSize = 4 * 1024 * 1024 + 17
        var decryptedData = Data()
        let encryptedBytes = Array(encryptedData)
        var offset = 0

        while offset < encryptedBytes.count {
            let end = min(offset + decryptionChunkSize, encryptedBytes.count)
            let chunk = Array(encryptedBytes[offset..<end])

            guard let (decryptedChunk, _) = stream.pull(cipherText: chunk) else {
                return nil
            }

            decryptedData.append(contentsOf: decryptedChunk)
            offset = end
        }

        return decryptedData
    }
}
