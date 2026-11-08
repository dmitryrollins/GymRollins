import { ApiError } from '../http/errors.ts'

// The refusals of the gym, photo and moderation routes (spec section 6). The codes keep the strings the Postgres
// functions and the bucket trigger raised, so the app's mappers and messages stay the same. The messages are the app's
// own words where it has them.
const refusal = (status: 403 | 409 | 422, code: string, message: string) => () => new ApiError(status, code, message)

export const Refusals = {
  dailyLimit: refusal(422, 'daily_limit', "You've shared a lot today. Try again tomorrow."),
  gymNotShareable: refusal(422, 'gym_not_shareable', "This gym can't take shared equipment."),
  gymFull: refusal(422, 'gym_full', 'This gym has as much shared equipment as it can hold.'),
  photoMissing: refusal(422, 'photo_missing', "That photo isn't uploaded."),
  photoInUse: refusal(422, 'photo_in_use', 'That photo already belongs to a listing.'),
  photoDailyLimit: refusal(422, 'photo_daily_limit', "You've uploaded a lot of photos today. Try again tomorrow."),
  photoNameInUse: refusal(422, 'photo_name_in_use', 'A listing already uses that photo name.'),
  photoBadName: refusal(422, 'photo_bad_name', 'A photo name is a lowercase UUID and .jpg.'),
  photoNotJpeg: refusal(422, 'photo_not_jpeg', 'Photos must be JPEG.'),
  photoOwnerMissing: refusal(422, 'photo_owner_missing', 'The account for this photo no longer exists.'),
  photoDuplicate: refusal(409, 'duplicate', 'A photo with that name is already uploaded.'),
  placeTaken: refusal(422, 'place_taken', 'Another gym now has this place.'),
  unknownTarget: refusal(422, 'unknown_target', 'unknown target'),
  unknownListing: refusal(422, 'unknown_listing', 'unknown listing'),
  notAllowed: refusal(403, 'not_allowed', 'Not allowed.'),
} as const
