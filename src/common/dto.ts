/**
 * Covia Backend DTOs — Data Transfer Object types for API requests and responses.
 */

/** Base DTO with common fields. */
export type BaseDto = {
  id: string;
  createdAt: string;
  updatedAt?: string;
};

/** User profile DTO. */
export type UserProfileDto = BaseDto & {
  email: string;
  fullName: string | null;
  username: string | null;
  phone: string | null;
  avatarUrl: string | null;
  isVerified: boolean;
  reliabilityScore: number;
};

/** Ride DTO. */
export type RideDto = BaseDto & {
  hostId: string;
  origin: string;
  destination: string;
  departureTime: string;
  seats: number;
  availableSeats: number;
  fare: number | null;
  fareMode: string;
  status: string;
  vehicleInfo?: string;
  notes?: string;
};

/** Ride request DTO. */
export type RideRequestDto = BaseDto & {
  rideId: string;
  requesterId: string;
  status: string;
  message?: string;
};

/** Chat message DTO. */
export type ChatMessageDto = BaseDto & {
  roomId: string;
  senderId: string;
  content: string;
  type: string;
  isEdited: boolean;
  isDeleted: boolean;
};

/** Notification DTO. */
export type NotificationDto = BaseDto & {
  userId: string;
  type: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  isRead: boolean;
};

/** Verification submission DTO. */
export type VerificationDto = BaseDto & {
  userId: string;
  documentType: string;
  documentUrl: string;
  status: string;
  reviewedBy?: string;
  reviewedAt?: string;
  rejectionReason?: string;
};

/** Feedback DTO. */
export type FeedbackDto = BaseDto & {
  userId?: string;
  category: string;
  description: string;
  screenshotUrl?: string;
  appVersion: string;
  deviceInfo: Record<string, unknown>;
};

/** Admin audit log DTO. */
export type AuditLogDto = BaseDto & {
  adminId: string;
  action: string;
  targetType: string;
  targetId: string;
  details?: Record<string, unknown>;
};
