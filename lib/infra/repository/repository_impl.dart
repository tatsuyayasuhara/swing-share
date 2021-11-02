import 'dart:developer';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart';
import 'package:swing_share/domain/model/comment.dart' as domain;
import 'package:swing_share/domain/model/post.dart' as domain;
import 'package:swing_share/domain/model/profile.dart' as domain;
import 'package:swing_share/domain/repository/repository.dart';
import 'package:swing_share/infra/model/comment.dart';
import 'package:swing_share/infra/model/post.dart';
import 'package:swing_share/infra/model/profile.dart';
import 'package:swing_share/infra/service/auth_service_impl.dart';
import 'package:swing_share/infra/service/firestore/api_path.dart';
import 'package:swing_share/infra/service/firestore/firestore_service.dart';

String get documentIdFromCurrentDate => DateTime.now().toIso8601String();

final repo = Provider.autoDispose<Repository>((ref) {
  final auth = ref.watch(authStateChangesProvider);

  if (auth.asData?.value?.uid != null) {
    return RepositoryImpl(uid: auth.asData!.value!.uid);
  }

  return RepositoryImpl();
});

class RepositoryImpl implements Repository {
  RepositoryImpl({this.uid});
  final String? uid;

  final _service = FirestoreService.instance;
  final _storage = FirebaseStorage.instance;

  @override
  Future<void> deletePost(String postId) async {
    await _service.deleteData(path: APIPath.post(uid!, postId));
  }

  @override
  Future<List<domain.Post>> allPosts({DateTime? lastPostDateTime}) async {
    final posts = await _service.collectionGroupFuture<domain.Post>(
      path: 'posts',
      builder: (data, documentId) => Post.fromMap(data, documentId).toEntity(),
      queryBuilder: (query) {
        if (lastPostDateTime == null) {
          return query.orderBy('createdAt', descending: true).limit(10);
        }

        return query
            .orderBy('createdAt', descending: true)
            .startAfter([Timestamp.fromDate(lastPostDateTime)]).limit(10);
      },
    );

    // TODO: ローカルストレージ上にキャッシュがあれば、それを返却する。

    // TODO: キャッシュがなければ、Cloud Storageからダウンロードしてキャッシュする。
    // refを実際のURLに変換
    List<domain.Post> result = [];
    await Future.forEach(posts, (domain.Post e) async {
      String? imageStoragePath;
      if (e.imagePath != null) {
        try {
          imageStoragePath = await _storage.ref(e.imagePath).getDownloadURL();
        } catch (ex) {
          log('failed to download image: $ex');
        }
      }

      String? videoStoragePath;
      if (e.videoPath != null) {
        try {
          videoStoragePath = await _storage.ref(e.videoPath).getDownloadURL();
        } catch (ex) {
          log('failed to download video: $ex');
        }
      }

      result.add(
          e.copyWith(imagePath: imageStoragePath, videoPath: videoStoragePath));
    });

    return result;
  }

  @override
  Future<List<domain.Post>> myPosts({DateTime? lastPostDateTime}) async {
    return _service.collectionFuture<domain.Post>(
      path: APIPath.posts(uid!),
      builder: (data, documentId) => Post.fromMap(data, documentId).toEntity(),
      queryBuilder: (query) {
        if (lastPostDateTime == null) {
          return query.orderBy('createdAt', descending: true).limit(7);
        }

        return query
            .orderBy('createdAt', descending: true)
            .startAfter([Timestamp.fromDate(lastPostDateTime)]).limit(7);
      },
    );
  }

  @override
  Future<void> setProfile(Profile profile) async {
    await _service.setData(
        path: APIPath.user(profile.id!), data: profile.toMap());
  }

  @override
  Future<void> setPost(
      String body, String? localImagePath, String? localVideoPath) async {
    final profile = await _service.documentFuture<Profile>(
      path: APIPath.user(uid!),
      builder: (data, documentId) => Profile.fromMap(data, documentId),
    );

    final docId = documentIdFromCurrentDate;
    String? imagePath;

    if (localImagePath != null) {
      imagePath = '${APIPath.post(uid!, docId)}/${basename(localImagePath)}';
      await FirebaseStorage.instance
          .ref(imagePath)
          .putFile(File(localImagePath));
    }

    String? videoPath;

    if (localVideoPath != null) {
      videoPath = '${APIPath.post(uid!, docId)}/${basename(localVideoPath)}';
      await FirebaseStorage.instance
          .ref(videoPath)
          .putFile(File(localVideoPath));
    }

    await _service.setData(
      path: APIPath.post(uid!, docId),
      data: <String, dynamic>{
        'author': <String, dynamic>{
          'name': profile.name,
          'ref': 'users/$uid',
          'thumbnailPath': profile.thumbnailPath,
        },
        'body': body,
        'createdAt': DateTime.now(),
        'imagePath': imagePath,
        'videoPath': videoPath,
      },
    );
  }

  @override
  Future<domain.Profile> profile() {
    return _service.documentFuture(
      path: APIPath.user(uid!),
      builder: (data, documentId) =>
          Profile.fromMap(data, documentId).toEntity(),
    );
  }

  @override
  Future<void> setComment(
      String body, String postedProfileId, String postId, int count) async {
    final profile = await _service.documentFuture<Profile>(
      path: APIPath.user(uid!),
      builder: (data, documentId) => Profile.fromMap(data, documentId),
    );

    await _service.setData(
      path: APIPath.comment(postedProfileId, postId, documentIdFromCurrentDate),
      data: <String, dynamic>{
        'author': <String, dynamic>{
          'name': profile.name,
          'ref': 'users/$uid',
          'thumbnailPath': profile.thumbnailPath,
        },
        'body': body,
        'createdAt': DateTime.now(),
      },
    );

    await _updateCommentCount(postedProfileId, postId, count);
  }

  Future<void> _updateCommentCount(
      String postedProfileId, String postId, int count) async {
    await _service.updateData(
      path: APIPath.post(postedProfileId, postId),
      data: <String, dynamic>{'commentCount': count},
    );
  }

  @override
  Future<void> deleteComment(String postedProfileId, String postId,
      String commentId, int count) async {
    await _service.deleteData(
        path: APIPath.comment(postedProfileId, postId, commentId));
    await _updateCommentCount(postedProfileId, postId, count);
  }

  @override
  Stream<List<domain.Comment>> postCommentsStream(
      String profileId, String postId) {
    return _service.collectionStream<domain.Comment>(
      path: APIPath.comments(profileId, postId),
      builder: (data, documentId) =>
          Comment.fromMap(data, documentId).toEntity(),
      sort: (lhs, rhs) => lhs.createdAt!.compareTo(rhs.createdAt!),
    );
  }

  @override
  Future<List<domain.Comment>> postComments(
      String profileId, String postId) async {
    return _service.collectionFuture<domain.Comment>(
      path: APIPath.comments(profileId, postId),
      builder: (data, documentId) =>
          Comment.fromMap(data, documentId).toEntity(),
    );
  }

  @override
  Future<List<domain.Comment>> userComments() {
    // TODO: implement userComments
    throw UnimplementedError();
  }
}
