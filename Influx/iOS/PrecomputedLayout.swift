// A collection view layout that only reads precomputed offsets. It never
// measures anything, so it is cheap for any number of rows.
import UIKit

final class PrecomputedLayout: UICollectionViewLayout {
    weak var model: TimelineModel?

    private var rowCount: Int {
        guard let collectionView, collectionView.numberOfSections > 0, let model else { return 0 }
        return min(collectionView.numberOfItems(inSection: 0), model.count)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: model?.totalHeight ?? 0)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let model else { return [] }
        let count = rowCount
        guard count > 0 else { return [] }
        var index = model.row(at: max(rect.minY, 0))
        var result: [UICollectionViewLayoutAttributes] = []
        while index < count, model.offsets[index] < rect.maxY {
            result.append(attributes(row: index, model: model))
            index += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let model, indexPath.item < rowCount else { return nil }
        return attributes(row: indexPath.item, model: model)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    private func attributes(row: Int, model: TimelineModel) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: row, section: 0))
        attributes.frame = model.frame(ofRow: row)
        return attributes
    }
}
