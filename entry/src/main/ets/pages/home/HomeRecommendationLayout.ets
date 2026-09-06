const HOME_RECOMMENDATION_COLUMNS: number = 2;
const HOME_RECOMMENDATION_PAGE_LIMIT: number = 4;
const HOME_RECOMMENDATION_CARD_HEIGHT: number = 178;
const HOME_RECOMMENDATION_ROW_GAP: number = 12;

export function homeRecommendationGridHeight(itemCount: number): number {
  let normalizedCount = Math.max(0, Math.min(HOME_RECOMMENDATION_PAGE_LIMIT, Math.floor(itemCount)));
  if (normalizedCount === 0) {
    return 0;
  }
  let rowCount = Math.ceil(normalizedCount / HOME_RECOMMENDATION_COLUMNS);
  return rowCount * HOME_RECOMMENDATION_CARD_HEIGHT + (rowCount - 1) * HOME_RECOMMENDATION_ROW_GAP;
}
