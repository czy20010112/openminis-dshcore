//
//  DSHImageOmission.swift
//  Minis
//
//  The model-facing text an omitted image is replaced with, ported from
//  DeepSeek Harness `packages/llm/llm/src/content.ts` — `offloadedImageText`
//  (`:108-122`), `imageIdentity` (`:49-53`) and `normalizedAccessText`
//  (`:65-69`).
//
//  WHY IT IS ITS OWN FILE, and why the string is built here rather than at each
//  omission site. Upstream has exactly ONE builder for this text, and it is
//  route-owned: `offloadedImageText(ref, access)` is called by the DeepSeek
//  adapter's image projection (`packages/llm/llm-deepseek/src/images.ts:43`) and
//  again by its pricing pass (`packages/llm/llm-deepseek/src/request-pricing.ts:102`),
//  so the placeholder a request sends and the placeholder it is priced at are the
//  same string by construction. This app had TWO builders — one for the
//  session-trim path (`AIChatViewModel+Offloading.imagePlaceholderText`) and one
//  for the request-budget path (`AIChatViewModel+RequestBudget.elidedImagePlaceholder`)
//  — with different wording, different fields, and no shared owner. A model that
//  saw the same image dropped by two different passes was told two different
//  things about it. Both now call `DSHImageOmission.text`, which is this one
//  function.
//
//  What upstream guarantees about the replacement, and what that costs us:
//
//   1. It NEVER says nothing. `replaceOffloadedImages` (`content.ts:227-241`)
//      substitutes a text block for every marked occurrence, so the occurrence
//      count a model reasons over is unchanged. Anything that deletes the block
//      instead of replacing it is wrong.
//   2. It NAMES the image. `imageIdentity` (`:49-53`) is the display name when the
//      attachment has one — JSON-quoted, then the durable id in parentheses — and
//      the bare id when it does not.
//   3. It gives an ADDRESSABLE PATH when one exists, and says so plainly when one
//      does not: `No local normalized image path is available; ask the user to
//      attach it again if needed.` (`:114`). The two branches differ only in that
//      clause, which is what makes "recoverable" and "not recoverable" tellable
//      apart from the text alone.
//   4. It carries the intrinsics a model needs to talk about the image it can no
//      longer see — `(WxHpx, mediaType)` — and the re-encode caveat
//      (`:66-68`), because the path names a normalized copy that may differ from
//      the source it was derived from.
//
//  THE ONE DELIBERATE ADDITION, and why it is an addition rather than a change:
//  this app's omission paths keep the original byte count and pixel size of the
//  bytes they just dropped (`imagePlaceholderText`'s `dims`), and the operator
//  reads that figure in the transcript. Upstream has no equivalent because its
//  placeholder is recomputed per request from a durable mark and never lands in
//  the log at all; ours is a durable rewrite (see `trimOldImagesFromHistory`), so
//  the figure is the only surviving record of the image's size. It rides inside
//  upstream's metadata parenthesis, which is the same slot upstream already uses
//  for `(WxHpx, mediaType)` — the upstream sentence is preserved verbatim around
//  it, so a model reading the clause sees upstream's text plus one more fact,
//  never a differently-worded instruction.
//
//  [T-image-offload-port]
//

import Foundation

/// The model-facing replacement text for one image omitted from a request.
///
/// Deliberately an enum of static functions: this is a string contract with a
/// model, not a service, and the two call sites that used to own separate copies
/// of it must not be able to drift again.
enum DSHImageOmission {

    /// The upstream sentence, with the metadata clause parameterised.
    ///
    /// `offloadedImageText` (`content.ts:108-122`) has exactly two shapes and they
    /// differ only in the tail:
    ///
    ///     [image omitted to fit request image limits; <identity>.<metadata><tail>]
    ///
    /// where `<tail>` is upstream's re-encode clause when a path is addressable,
    /// and `No local normalized image path is available; ask the user to attach it
    /// again if needed.` when it is not (`:114`). Both tails are literals below so
    /// neither can be dropped by an edit to the assembly.
    ///
    /// - Parameters:
    ///   - identity: what the image is named by. Upstream's `imageIdentity` shape —
    ///     `"photo.jpg" (sha256:ab…)` when the source has a display name, the bare
    ///     durable id otherwise. Callers that hold no id pass `noIdentity`.
    ///   - path: a path a model tool can read the bytes from, or nil when no
    ///     addressable copy exists.
    ///   - pixelSize: pixel dimensions, rendered where upstream renders them.
    ///   - mediaType: the image's media type, rendered beside the dimensions.
    ///   - byteCount: size of the bytes this occurrence carried, or nil. See the
    ///     file header for why this field exists here and not upstream.
    /// - Returns: the placeholder text, in upstream's wording and field order.
    static func text(
        identity: String,
        path: String?,
        pixelSize: (width: Int, height: Int)?,
        mediaType: String,
        byteCount: Int?
    ) -> String {
        var head = "[image omitted to fit request image limits; \(identity)."
        var meta: [String] = []
        if let size = pixelSize { meta.append("\(size.width)x\(size.height)px") }
        meta.append(mediaType)
        if let bytes = byteCount { meta.append("\(bytes) bytes") }
        head += " (\(meta.joined(separator: ", ")))"

        guard let path else { return head + noPathClause + "]" }
        return head + normalizedAccessText(path: path, mediaType: mediaType) + "]"
    }

    /// The identity used when the caller holds no attachment id for the
    /// occurrence. Never an invented label: a fabricated name would read as a fact
    /// about the image, and `imageIdentity`'s whole point is that the name it
    /// prints is the one the attachment actually has.
    static let noIdentity = "attachment"

    /// Upstream's no-path tail (`content.ts:114`), verbatim.
    static let noPathClause =
        " No local normalized image path is available; ask the user to attach it again if needed."

    /// Upstream's path tail (`content.ts:65-69`), with the extension clause
    /// stated once for every media type this app can omit.
    ///
    /// Upstream derives the extension from `ImageMediaType` through `extension()`
    /// (`:55-63`) and offers exactly `.png/.jpg/.webp/.gif`. This app omits HEIC
    /// as well (`image/jpeg`-normalized on the way in, but the original bytes can
    /// be `.heic`), so the clause names the four upstream extensions rather than
    /// naming one it might get wrong.
    static func normalizedAccessText(path: String, mediaType: String) -> String {
        " Normalized copy (read-only; may be resized or re-encoded): \"\(path)\" (\(mediaType))."
            + " Source dimensions, format, and byte size may differ."
            + " Copy to a writable path ending in .jpg/.png/.webp/.gif before editing."
    }
}
