// The macOS twin of the iOS layout. It only reads precomputed
// offsets and never measures.
import AppKit

final class PrecomputedLayout: NSCollectionViewLayout {
    weak var model: TimelineModel?

    private var rowCount: Int {
        guard let collectionView, collectionView.numberOfSections > 0, let model else { return 0 }
        return min(collectionView.numberOfItems(inSection: 0), model.count)
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.enclosingScrollView?.contentSize.width ?? 0, height: model?.totalHeight ?? 0)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard let model else { return [] }
        let count = rowCount
        guard count > 0 else { return [] }
        var index = model.row(at: max(rect.minY, 0))
        var result: [NSCollectionViewLayoutAttributes] = []
        while index < count, model.offsets[index] < rect.maxY {
            result.append(attributes(row: index, model: model))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let model, indexPath.item < rowCount else { return nil }
        return attributes(row: indexPath.item, model: model)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    private func attributes(row: Int, model: TimelineModel) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: row, section: 0))
        attributes.frame = model.frame(ofRow: row)
        return attributes
    }
}
